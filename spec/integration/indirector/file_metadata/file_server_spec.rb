require 'spec_helper'

require 'puppet/indirector/file_metadata/file_server'
require 'shared_behaviours/file_server_terminus'

require 'puppet_spec/files'

describe Puppet::Indirector::FileMetadata::FileServer, " when finding files" do
  it_should_behave_like "Puppet::Indirector::FileServerTerminus"
  include PuppetSpec::Files
  include_context 'with supported checksum types'

  before do
    @terminus = Puppet::Indirector::FileMetadata::FileServer.new
    @test_class = Puppet::FileServing::Metadata
    Puppet::FileServing::Configuration.instance_variable_set(:@configuration, nil)
  end

  describe "with a plugin environment specified in the request" do
    with_checksum_types("file_content_with_env", "mod/lib/file.rb") do
      it "should return the correct metadata" do
        Puppet.settings[:modulepath] = "/no/such/file"
        env = Puppet::Node::Environment.create(:foo, [env_path])
        result = Puppet::FileServing::Metadata.indirection.search("plugins", :environment => env, :checksum_type => checksum_type, :recurse => true)

        expect(result).to_not be_nil
        expect(result.length).to eq(2)
        result.map {|x| expect(x).to be_instance_of(Puppet::FileServing::Metadata)}
        expect_correct_checksum(result.find {|x| x.relative_path == 'file.rb'}, checksum_type, checksum, Puppet::FileServing::Metadata)
      end
    end
  end

  describe "in modules" do
    with_checksum_types("file_content", "mymod/files/myfile") do
      it "should return the correct metadata" do
        env = Puppet::Node::Environment.create(:foo, [env_path])
        result = Puppet::FileServing::Metadata.indirection.find("modules/mymod/myfile", :environment => env, :checksum_type => checksum_type)
        expect_correct_checksum(result, checksum_type, checksum, Puppet::FileServing::Metadata)
      end
    end
  end

  describe "that are tasks in modules" do
    with_checksum_types("task_file_content", "mymod/tasks/mytask") do
      it "should return the correct metadata" do
        env = Puppet::Node::Environment.create(:foo, [env_path])
        result = Puppet::FileServing::Metadata.indirection.find("tasks/mymod/mytask", :environment => env, :checksum_type => checksum_type)
        expect_correct_checksum(result, checksum_type, checksum, Puppet::FileServing::Metadata)
      end
    end
  end

  describe "when node name expansions are used" do
    with_checksum_types("file_server_testing", "mynode/myfile") do
      it "should return the correct metadata" do
        allow(Puppet::FileSystem).to receive(:exist?).with(checksum_file).and_return(true)
        allow(Puppet::FileSystem).to receive(:exist?).with(Puppet[:fileserverconfig]).and_return(true)

        # Use a real mount, so the integration is a bit deeper.
        mount1 = Puppet::FileServing::Configuration::Mount::File.new("one")
        mount1.path = File.join(env_path, "%h")

        parser = double('parser', :changed? => false)
        allow(parser).to receive(:parse).and_return("one" => mount1)

        allow(Puppet::FileServing::Configuration::Parser).to receive(:new).and_return(parser)
        env = Puppet::Node::Environment.create(:foo, [])

        result = Puppet::FileServing::Metadata.indirection.find("one/myfile", :environment => env, :node => "mynode", :checksum_type => checksum_type)
        expect_correct_checksum(result, checksum_type, checksum, Puppet::FileServing::Metadata)
      end
    end
  end

  describe "when modules provide the same plugin files" do
    include PuppetSpec::Files

    let(:modulepath) do
      dir_containing('modules', {
        'first' => { 'lib' => { 'puppet' => {
          'functions' => { 'shared.rb' => 'first', 'first.rb' => '' },
          'type' => { 'conflict' => 'a file' },
        } } },
        'second' => { 'lib' => { 'puppet' => {
          'functions' => { 'shared.rb' => 'second', 'second.rb' => '' },
          'type' => { 'conflict' => { 'nested.rb' => '' } },
        } } },
        'third' => { 'lib' => { 'puppet' => { 'functions' => { 'third.rb' => '' } } } },
      })
    end
    let(:env) { Puppet::Node::Environment.create(:dupes, [modulepath]) }

    def search
      Puppet::FileServing::Metadata.indirection.search("plugins", :environment => env, :recurse => true)
    end

    def duplicate_warnings
      @logs.select { |log| log.level == :warning && log.message =~ /provided by more than one directory/ }
    end

    def path_of(module_name, *parts)
      File.join(modulepath, module_name, 'lib', 'puppet', *parts)
    end

    it "warns about the files that are provided more than once" do
      result = search
      used = result.find { |m| m.relative_path == 'puppet/functions/shared.rb' }.full_path
      ignored = ([path_of('first', 'functions', 'shared.rb'), path_of('second', 'functions', 'shared.rb')] - [used]).first

      expect(duplicate_warnings.length).to eq(1)
      message = duplicate_warnings.first.message
      expect(message).to include("'plugins' mount in environment 'dupes'")
      expect(message).to include("puppet/functions/shared.rb: using #{used}, ignoring #{ignored}")
      expect(message).to include("puppet/type/conflict: using ")
    end

    it "does not warn about directories that are provided more than once" do
      search

      expect(duplicate_warnings.first.message).not_to match(%r{puppet/functions:|puppet:|\.:})
    end

    it "only warns once for the same duplicates" do
      search
      search

      expect(duplicate_warnings.length).to eq(1)
    end

    it "does not warn when no files are provided more than once" do
      FileUtils.rm_rf(File.join(modulepath, 'second'))
      search

      expect(duplicate_warnings).to be_empty
    end

    it "limits the number of files listed" do
      21.times do |i|
        %w[first second].each do |mod|
          File.write(File.join(modulepath, mod, 'lib', 'puppet', 'functions', "extra#{i}.rb"), '')
        end
      end
      search

      message = duplicate_warnings.first.message
      expect(message.lines.count { |line| line.include?(': using ') }).to eq(Puppet::Indirector::FileServer::MAX_DUPLICATES_LISTED)
      expect(message).to include('(and 3 more)')
    end
  end
end
