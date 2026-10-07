# frozen_string_literal: true

require_relative '../../puppet/file_serving/configuration'
require_relative '../../puppet/file_serving/fileset'
require_relative '../../puppet/file_serving/terminus_helper'
require_relative '../../puppet/indirector/terminus'

# Look files up using the file server.
class Puppet::Indirector::FileServer < Puppet::Indirector::Terminus
  include Puppet::FileServing::TerminusHelper

  # The most files to list when warning about files provided more than once
  MAX_DUPLICATES_LISTED = 20

  # Is the client authorized to perform this action?
  def authorized?(request)
    return false unless [:find, :search].include?(request.method)

    mount, _ = configuration.split_path(request)

    # If we're not serving this mount, then access is denied.
    return false unless mount

    true
  end

  # Find our key using the fileserver.
  def find(request)
    mount, relative_path = configuration.split_path(request)

    return nil unless mount

    # The mount checks to see if the file exists, and returns nil
    # if not.
    path = mount.find(relative_path, request)
    return nil unless path

    path2instance(request, path)
  end

  # Search for files.  This returns an array rather than a single
  # file.
  def search(request)
    mount, relative_path = configuration.split_path(request)

    paths = mount.search(relative_path, request) if mount
    unless paths
      Puppet.info _("Could not find filesystem info for file '%{request}' in environment %{env}") % { request: request.key, env: request.environment }
      return nil
    end
    duplicates = []
    instances = path2instances(request, *paths) do |file, used_path, ignored_path|
      duplicates << [file, used_path, ignored_path] if conflicting_files?(file, used_path, ignored_path)
    end
    warn_about_duplicates(mount, request, duplicates) unless duplicates.empty?
    instances
  end

  private

  # Mounts like `plugins` merge several directories, so directories such as
  # `puppet/functions` are naturally found in more than one of them. Only
  # files conflict, since only one copy of each can be served.
  def conflicting_files?(file, used_path, ignored_path)
    return false if file == '.'

    !(File.directory?(File.join(used_path, file)) && File.directory?(File.join(ignored_path, file)))
  end

  # Warn once per environment and mount about files that are provided by
  # more than one directory, e.g. two modules that both ship
  # `lib/puppet/functions/foo.rb`. The warning is repeated only if the
  # duplicates change, since every agent run searches the mount again.
  def warn_about_duplicates(mount, request, duplicates)
    environment = request.environment.to_s
    listed = duplicates.first(MAX_DUPLICATES_LISTED).map do |file, used_path, ignored_path|
      "\n   " + _("%{file}: using %{used}, ignoring %{ignored}") % {
        file: file, used: File.join(used_path, file), ignored: File.join(ignored_path, file)
      }
    end
    if duplicates.length > MAX_DUPLICATES_LISTED
      listed << "\n   " + _("(and %{count} more)") % { count: duplicates.length - MAX_DUPLICATES_LISTED }
    end

    message = _("Some files in the '%{mount}' mount in environment '%{environment}' are provided by more than one directory; only one copy of each is served:") % {
      mount: mount.name, environment: environment
    }
    Puppet.warn_once('duplicate_mount_files', [:duplicate_mount_files, environment, mount.name, duplicates], message + listed.join, :default, :default)
  end

  # Our fileserver configuration, if needed.
  def configuration
    Puppet::FileServing::Configuration.configuration
  end
end
