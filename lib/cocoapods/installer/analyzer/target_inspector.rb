module Pod
  class Installer
    class Analyzer
      class TargetInspector
        include Config::Mixin

        # @return [TargetDefinition] the target definition to inspect
        #
        attr_accessor :target_definition

        # Initialize a new instance
        #
        # @param [TargetDefinition] target_definition
        #        the target definition
        #
        def initialize(target_definition)
          @target_definition = target_definition
        end

        # Inspect the #target_definition
        #
        # @return [TargetInspectionResult]
        #
        def inspect!
          project_path = compute_project_path
          user_project = Xcodeproj::Project.open(project_path)
          targets = compute_targets(user_project)

          result = TargetInspectionResult.new
          result.target_definition = target_definition
          result.project_path = project_path
          result.project_target_uuids = targets.map(&:uuid)
          result.build_configurations = compute_build_configurations(targets)
          result.platform = compute_platform(targets)
          result.archs = compute_archs(targets)
          result
        end

        #-----------------------------------------------------------------------#

        private

        # Returns the path of the user project that the #target_definition
        # should integrate.
        #
        # @raise  If the project is implicit and there are multiple projects.
        #
        # @raise  If the path doesn't exits.
        #
        # @return [Pathname] the path of the user project.
        #
        def compute_project_path
          if target_definition.user_project_path
            path = config.installation_root + target_definition.user_project_path
            path = "#{path}.xcodeproj" unless File.extname(path) == '.xcodeproj'
            path = Pathname.new(path)
            unless path.exist?
              raise Informative, 'Unable to find the Xcode project ' \
              "`#{path}` for the target `#{target_definition.label}`."
            end
          else
            xcodeprojs = config.installation_root.children.select { |e| e.fnmatch('*.xcodeproj') }
            if xcodeprojs.size == 1
              path = xcodeprojs.first
            else
              raise Informative, 'Could not automatically select an Xcode project. ' \
              "Specify one in your Podfile like so:\n\n" \
              "    xcodeproj 'path/to/Project.xcodeproj'\n"
            end
          end
          path
        end

        # Returns a list of the targets from the project of #target_definition
        # that needs to be integrated.
        #
        # @note   The method first looks if there is a target specified with
        #         the `link_with` option of the {TargetDefinition}. Otherwise
        #         it looks for the target that has the same name of the target
        #         definition.  Finally if no target was found the first
        #         encountered target is returned (it is assumed to be the one
        #         to integrate in simple projects).
        #
        # @param  [Xcodeproj::Project] user_project
        #         the user project
        #
        # @return [Array<PBXNativeTarget>]
        #
        def compute_targets(user_project)
          native_targets = user_project.native_targets
          if link_with = target_definition.link_with
            targets = native_targets.select { |t| link_with.include?(t.name) }
            raise Informative, "Unable to find the targets named `#{link_with.to_sentence}` to link with target definition `#{target_definition.name}`" if targets.empty?
          elsif target_definition.link_with_first_target?
            targets = [native_targets.first].compact
            raise Informative, 'Unable to find a target' if targets.empty?
          else
            target = native_targets.find { |t| t.name == target_definition.name.to_s }
            targets = [target].compact
            raise Informative, "Unable to find a target named `#{target_definition.name}`" if targets.empty?
          end
          targets
        end

        # @param  [Array<PBXNativeTarget] the user's targets of the project of
        #         #target_definition which needs to be integrated
        #
        # @return [Hash{String=>Symbol}] A hash representing the user build
        #         configurations where each key corresponds to the name of a
        #         configuration and its value to its type (`:debug` or `:release`).
        #
        def compute_build_configurations(user_targets)
          if user_targets
            user_targets.map { |t| t.build_configurations.map(&:name) }.flatten.each_with_object({}) do |name, hash|
              hash[name] = name == 'Debug' ? :debug : :release
            end.merge(target_definition.build_configurations || {})
          else
            target_definition.build_configurations || {}
          end
        end

        # @param  [Array<PBXNativeTarget] the user's targets of the project of
        #         #target_definition which needs to be integrated
        #
        # @return [Platform] The platform of the user's targets
        #
        # @note   This resolves to the lowest deployment target across the user
        #         targets.
        #
        # @todo   Is assigning the platform to the target definition the best way
        #         to go?
        #
        def compute_platform(user_targets)
          return target_definition.platform if target_definition.platform
          name = nil
          deployment_target = nil

          user_targets.each do |target|
            name ||= target.platform_name
            raise Informative, 'Targets with different platforms' unless name == target.platform_name
            if !deployment_target || deployment_target > Version.new(target.deployment_target)
              deployment_target = Version.new(target.deployment_target)
            end
          end

          target_definition.set_platform(name, deployment_target)
          Platform.new(name, deployment_target)
        end

        # Computes the architectures relevant for the user's targets.
        #
        # @param  [Array<PBXNativeTarget] the user's targets of the project of
        #         #target_definition which needs to be integrated
        #
        # @return [Array<String>]
        #
        def compute_archs(user_targets)
          archs = []
          user_targets.each do |target|
            target_archs = target.common_resolved_build_setting('ARCHS')
            archs.concat(Array(target_archs))
          end

          archs = archs.compact.uniq.sort
          UI.message('Using `ARCHS` setting to build architectures of ' \
                   "target `#{target_definition.label}`: " \
                   "(`#{archs.join('`, `')}`)")
          archs.length > 1 ? archs : archs.first
        end

        # Checks if any of the targets for the {TargetDefinition} computed before
        # by #compute_user_project_targets is recommended to be build as a framework
        # due the presence of Swift source code in any of the source build phases.
        #
        # @param  [TargetDefinition] target_definition
        #         the target definition
        #
        # @param  [Array<PBXNativeTarget>] native_targets
        #         the targets which are checked for presence of Swift source code
        #
        # @return [Boolean] Whether the user project targets to integrate into
        #         uses Swift
        #
        def compute_recommends_frameworks(target_definition, native_targets)
          file_predicate = nil
          file_predicate = proc do |file_ref|
            if file_ref.respond_to?(:last_known_file_type)
              file_ref.last_known_file_type == 'sourcecode.swift'
            elsif file_ref.respond_to?(:files)
              file_ref.files.any?(&file_predicate)
            else
              false
            end
          end
          target_definition.platform.supports_dynamic_frameworks? || native_targets.any? do |target|
            target.source_build_phase.files.any? do |build_file|
              file_predicate.call(build_file.file_ref)
            end
          end
        end

      end
    end
  end
end