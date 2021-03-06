require 'yaml'
require 'albacore/logging'
require 'albacore/project'
require 'xsemver'

module Albacore
  # a spec object
  class AppSpec
    include ::Albacore::Logging

    # Create a new app spec from yaml data; will use heuristics to let the
    # developer avoid as much typing and definition mongering as possible; for
    # details see the unit tests and the documentation for this class.
    #
    # @descriptor_path [String] The location of the descriptor file (the .appspec)
    # @data [String] A yaml-containing string
    # @semver [::XSemVer] An optional semver instance that can be queried for what
    #   version the package has.
    def initialize descriptor_path, data, semver = nil
      raise ArgumentError, 'data is nil' unless data
      @path = descriptor_path
      @conf = YAML.load(data) || Hash.new

      project_path = resolve_project descriptor_path, @conf
      raise ArgumentError, "couldn't find project, descriptor_path: #{descriptor_path.inspect}" unless valid_path project_path

      @proj = Project.new project_path
      @semver = semver
    end

    # Gets the path that the .appspec file was read from when it was initialised.
    #
    def path
      @path
    end

    # Gets the executable name if this service has one -- defaults to the
    # assembly name of the corresponding project, plus 'exe', which is how the
    # compilers name the executables.
    #
    def exe
      conf['exe'] || "#{proj.asmname}.exe"
    end

    # Resolves the project file given an optional descriptor path or a
    # configuration hash or both. One of the other of the parameters need to
    # exist, or an error will be thrown.
    #
    # @param descriptor_path May be nil
    # @param conf [#[]] A hash or something indexable
    def resolve_project descriptor_path, conf
      trace { "trying to resolve project, descriptor_path: #{descriptor_path.inspect}, conf: #{conf.inspect} [AppSpec#resolve_path]" }

      project_path = conf['project_path']
      return File.join File.dirname(descriptor_path), project_path if project_path and valid_path descriptor_path

      trace { 'didn\'t have both a project_path and a descriptor_path that was valid [AppSpec#resolve_project]' }
      return project_path if project_path
      find_first_project descriptor_path
    end

    # Given a descriptor path, tries to find the first matching project file. If
    # you have multiple project files, the order of which {Dir#glob} returns
    # values will determine which is chosen
    def find_first_project descriptor_path
      trace { "didn't have a valid project_path, trying to find first project at #{descriptor_path.inspect}" }
      dir = File.dirname descriptor_path
      abs_dir = File.expand_path dir
      Dir.glob(File.join(abs_dir, '*proj')).first
    end

    # path of the *.appspec
    attr_reader :path

    # the loaded configuration in that appspec
    attr_reader :conf

    # the project the spec applies to
    attr_reader :proj

    # gets the fully qualified path of the directory where the appspec file is
    def dir_path
      File.expand_path(File.dirname(@path))
    end

    # title for puppet, title for app, title for process running on server
    def title
      title_raw.downcase
    end

    # the title as-is without any downcasing
    def title_raw
      conf['title'] || proj.title
    end

    alias_method :id, :title_raw

    # the description that is used when installing and reading about the package in the
    # package manager
    def description
      conf['description'] || proj.description
    end

    # gets the uri source of the project
    def uri
      conf['uri'] || git_source
    end

    # gets the category this package is in, both for the RPM and for puppet and
    # for possibly assigning to a work-stealing cluster or to start the app in
    # the correct node-cluster if you have that implemented
    def category
      conf['category'] || 'apps'
    end

    # gets the license that the app is licensed under
    def license
      conf['license'] || proj.license
    end

    # gets the version with the following priorities:
    #  - semver version passed in c'tor
    #  - ENV['FORMAL_VERSION']
    #  - .appspec's version
    #  - .xxproj's version
    #  - semver from disk
    #  - if all above fails; use '1.0.0'
    def version
      semver_version || ENV['FORMAL_VERSION'] || conf['version'] || proj.version || semver_disk_version || '1.0.0'
    end

    # gets the binary folder, first from .appspec then from proj given a
    # configuration mode (default: Release)
    def bin_folder configuration = 'Release'
      conf['bin'] || proj.output_path(configuration)
    end

    # gets the folder that is used to keep configuration that defaults to the
    # current (.) directory
    def conf_folder
      conf['conf_folder'] || '.'
    end

    # gets an enumerable list of paths that are the 'main' contents of the
    # package
    #
    def contents
      conf['contents'] || []
    end

    # gets the provider to use to calculate the directory paths to construct
    # inside the nuget
    #
    # defaults to the 'defaults' provider which can be found in
    # 'albacore/app_spec/defaults.rb'
    def provider
      conf['provider'] || 'defaults'
    end

    # Gets the configured port to bind the site to
    #
    def port
      conf['port'] || '80'
    end

    # Gets the host header to use for the binding in IIS - defaults to *, i.e.
    # binding to all hosts
    #
    def host_header
      conf['host_header'] || '*'
    end

    # TODO: support a few of these:
    # https://github.com/bernd/fpm-cookery/wiki/Recipe-Specification

    # load the App Spec from a descriptor path
    def self.load descriptor_path
      raise ArgumentError, 'missing parameter descriptor_path' unless descriptor_path
      raise ArgumentError, 'descriptor_path does not exist' unless File.exists? descriptor_path
      AppSpec.new(descriptor_path, File.read(descriptor_path))
    end

    # Customizing the to_s implementation to make the spec more amenable for printing
    def to_s
      "AppSpec[#{title}], #{@conf.keys.length} keys]"
    end

    private
    # determines whether the passed path is valid and existing
    def valid_path path
      path and File.exists? path
    end

    # gets the source from the current git repository: finds the first remote and uses
    # that as the source of the RPM
    def git_source
      `git remote -v`.
        split(/\n/).
        map(&:chomp).
        map { |s| s.split(/\t/)[1].split(/ /)[0] }.
        first
    end

    # Gets the semver version in %M.%m.%p form or nil if a semver isn't given
    # in the c'tor of this class. If we have gotten an explicit version in the constructor,
    # let's assume that version should be used in front of anything else and that the calling
    # libraries know what they are doing.
    def semver_version
      return @semver.format '%M.%m.%p' if @semver
      nil
    end

    # if everything else fails, return the semver from disk
    def semver_disk_version
      v = XSemVer::SemVer.find
      v.format '%M.%m.%p' if v
    rescue SemVerMissingError
      nil
    end

    # Listen to all 'getters'
    #
    def method_missing name, *args, &block
      unless name =~ /\w=$/
        @conf.send(:'[]', *[name.to_s, args].flatten, &block)
      end
    end
  end
end
