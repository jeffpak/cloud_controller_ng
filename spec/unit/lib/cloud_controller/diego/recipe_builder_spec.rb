require 'spec_helper'

module VCAP::CloudController
  module Diego
    RSpec.describe RecipeBuilder do
      subject(:recipe_builder) { RecipeBuilder.new }

      describe '#build_staging_task' do
        let(:app) { AppModel.make(guid: 'banana-guid') }
        let(:staging_details) do
          Diego::StagingDetails.new.tap do |details|
            details.droplet               = droplet
            details.package               = package
            details.environment_variables = [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'nightshade_fruit', value: 'potato')]
            details.staging_memory_in_mb  = 42
            details.staging_disk_in_mb    = 51
            details.start_after_staging   = true
          end
        end
        let(:config) do
          {
            external_port:             external_port,
            internal_service_hostname: internal_service_hostname,
            internal_api:              {
              auth_user:     user,
              auth_password: password
            },
            staging:                   {
              timeout_in_seconds: 90,
            },
            diego:                     {
              use_privileged_containers_for_staging: false,
              stager_url:                            'http://stager.example.com',
            },
          }
        end
        let(:internal_service_hostname) { 'internal.awesome.sauce' }
        let(:external_port) { '7777' }
        let(:user) { 'user' }
        let(:password) { 'password' }
        let(:rule_dns_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol:     'udp',
            destinations: ['0.0.0.0/0'],
            ports:        [53]
          )
        end
        let(:rule_http_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol:     'tcp',
            destinations: ['0.0.0.0/0'],
            ports:        [80],
            log:          true
          )
        end
        let(:rule_staging_specific) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol:     'tcp',
            destinations: ['0.0.0.0/0'],
            ports:        [443],
            log:          true
          )
        end

        before do
          SecurityGroup.make(rules: [{ 'protocol' => 'udp', 'ports' => '53', 'destination' => '0.0.0.0/0' }], staging_default: true)
          SecurityGroup.make(rules: [{ 'protocol' => 'tcp', 'ports' => '80', 'destination' => '0.0.0.0/0', 'log' => true }], staging_default: true)
          security_group = SecurityGroup.make(rules: [{ 'protocol' => 'tcp', 'ports' => '443', 'destination' => '0.0.0.0/0', 'log' => true }], staging_default: false)
          security_group.add_staging_space(app.space)
        end

        context 'with a buildpack backend' do
          let(:droplet) { DropletModel.make(:buildpack, package: package, app: app) }
          let(:package) { PackageModel.make(app: app) }

          let(:buildpack_staging_action) { ::Diego::Bbs::Models::RunAction.new }
          let(:lifecycle_environment_variables) { [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'the-buildpack-env-var', value: 'the-buildpack-value')] }
          let(:lifecycle_cached_dependencies) { [::Diego::Bbs::Models::CachedDependency.new(name: 'buildpack_cached_deps')] }
          let(:lifecycle_action_builder) do
            instance_double(
              Buildpack::StagingActionBuilder,
              stack:                      'potato-stack',
              action:                     buildpack_staging_action,
              task_environment_variables: lifecycle_environment_variables,
              cached_dependencies:        lifecycle_cached_dependencies,
            )
          end

          let(:lifecycle_type) { 'buildpack' }
          let(:lifecycle_protocol) do
            instance_double(VCAP::CloudController::Diego::Buildpack::LifecycleProtocol,
              staging_action_builder: lifecycle_action_builder
            )
          end

          before do
            allow(LifecycleProtocol).to receive(:protocol_for_type).with(lifecycle_type).and_return(lifecycle_protocol)
          end

          it 'constructs a TaskDefinition with staging instructions' do
            result = recipe_builder.build_staging_task(config, staging_details)

            expect(result.root_fs).to eq('preloaded:potato-stack')
            expect(result.log_guid).to eq('banana-guid')
            expect(result.metrics_guid).to eq('')
            expect(result.log_source).to eq('STG')
            expect(result.result_file).to eq('/tmp/result.json')
            expect(result.privileged).to be(false)

            expect(result.memory_mb).to eq(42)
            expect(result.disk_mb).to eq(51)
            expect(result.cpu_weight).to eq(50)
            expect(result.legacy_download_user).to eq('vcap')

            annotation = JSON.parse(result.annotation)
            expect(annotation['lifecycle']).to eq(lifecycle_type)
            expect(annotation['completion_callback']).to eq("http://#{user}:#{password}@#{internal_service_hostname}:#{external_port}" \
                                   "/internal/v3/staging/#{droplet.guid}/droplet_completed?start=#{staging_details.start_after_staging}")

            timeout_action = result.action.timeout_action
            expect(timeout_action).not_to be_nil
            expect(timeout_action.timeout_ms).to eq(90 * 1000)

            expect(timeout_action.action.run_action).to eq(buildpack_staging_action)

            expect(result.egress_rules).to match_array([
              rule_dns_everywhere,
              rule_http_everywhere,
              rule_staging_specific,
            ])

            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)
          end

          it 'sets the completion callback to the stager callback url' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.completion_callback_url).to eq("http://stager.example.com/v1/staging/#{droplet.guid}/completed")
          end

          it 'gives the task a TrustedSystemCertificatesPath' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
          end

          it 'sets the env vars' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.environment_variables).to eq(lifecycle_environment_variables)
          end

          it 'raises errors from the lifecycle protocol as Stager API errors' do
          end
        end

        context 'with a docker backend' do
          let(:droplet) { DropletModel.make(:docker, package: package, app: app) }
          let(:package) { PackageModel.make(:docker, app: app) }

          let(:docker_staging_action) { ::Diego::Bbs::Models::RunAction.new }
          let(:lifecycle_type) { 'docker' }
          let(:lifecycle_environment_variables) { [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'the-docker-env-var', value: 'the-docker-value')] }
          let(:lifecycle_cached_dependencies) { [::Diego::Bbs::Models::CachedDependency.new(name: 'docker_cached_deps')] }
          let(:lifecycle_action_builder) do
            instance_double(
              Docker::StagingActionBuilder,
              stack:                      'docker-stack',
              action:                     docker_staging_action,
              task_environment_variables: lifecycle_environment_variables,
              cached_dependencies:        lifecycle_cached_dependencies,
            )
          end

          before do
            allow(Docker::StagingActionBuilder).to receive(:new).and_return(lifecycle_action_builder)
          end

          it 'sets the log guid' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.log_guid).to eq('banana-guid')
          end

          it 'sets the log source' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.log_source).to eq('STG')
          end

          it 'sets the result file' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.result_file).to eq('/tmp/result.json')
          end

          it 'sets privileged container to the config value' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.privileged).to be(false)
          end

          it 'sets the legacy download user' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.legacy_download_user).to eq('vcap')
          end

          it 'sets the annotation' do
            result = recipe_builder.build_staging_task(config, staging_details)

            annotation = JSON.parse(result.annotation)
            expect(annotation['lifecycle']).to eq(lifecycle_type)
            expect(annotation['completion_callback']).to eq("http://#{user}:#{password}@#{internal_service_hostname}:#{external_port}" \
                                   "/internal/v3/staging/#{droplet.guid}/droplet_completed?start=#{staging_details.start_after_staging}")
          end

          it 'sets the cached dependencies' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)
          end

          it 'sets the memory' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.memory_mb).to eq(42)
          end

          it 'sets the disk' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.disk_mb).to eq(51)
          end

          it 'sets the egress rules' do
            result = recipe_builder.build_staging_task(config, staging_details)

            expect(result.egress_rules).to match_array([
              rule_dns_everywhere,
              rule_http_everywhere,
              rule_staging_specific,
            ])
          end

          it 'sets the rootfs' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.root_fs).to eq('preloaded:docker-stack')
          end

          it 'sets the completion callback' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.completion_callback_url).to eq("http://stager.example.com/v1/staging/#{droplet.guid}/completed")
          end

          it 'sets the trusted cert path' do
            result = recipe_builder.build_staging_task(config, staging_details)
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
          end

          it 'sets the timeout and sets the run action' do
            result = recipe_builder.build_staging_task(config, staging_details)

            timeout_action = result.action.timeout_action
            expect(timeout_action).not_to be_nil
            expect(timeout_action.timeout_ms).to eq(90 * 1000)

            expect(timeout_action.action.run_action).to eq(docker_staging_action)
          end
        end
      end

      describe '#build_app_task' do
        let(:app) { AppModel.make(guid: 'banana-guid') }
        let(:task_details) do
          TaskModel.create(
            name:                 'potato-task',
            state:                 TaskModel::PENDING_STATE,
            droplet:               droplet,
            command:               'bin/start',
            app:                   app,
            disk_in_mb:            1024,
            memory_in_mb:          2048,
            sequence_id:           9
          )
        end
        let(:config) do
          {
            external_port:             external_port,
            internal_service_hostname: internal_service_hostname,
            internal_api:              {
              auth_user:     user,
              auth_password: password
            },
            staging:                   {
              timeout_in_seconds: 90,
            },
            diego:                     {
              lifecycle_bundles:                     { 'buildpack/potato-stack': 'potato_lifecycle_bundle_url' },
              use_privileged_containers_for_staging: false,
              stager_url:                            'http://stager.example.com',
            },
          }
        end
        let(:internal_service_hostname) { 'internal.awesome.sauce' }
        let(:external_port) { '7777' }
        let(:user) { 'user' }
        let(:password) { 'password' }
        let(:rule_dns_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol:     'udp',
            destinations: ['0.0.0.0/0'],
            ports:        [53]
          )
        end
        let(:rule_http_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol:     'tcp',
            destinations: ['0.0.0.0/0'],
            ports:        [80],
            log:          true
          )
        end

        before do
          SecurityGroup.make(rules: [{ 'protocol' => 'udp', 'ports' => '53', 'destination' => '0.0.0.0/0' }], running_default: true)
          app.space.add_security_group(
            SecurityGroup.make(rules: [{ 'protocol' => 'tcp', 'ports' => '80', 'destination' => '0.0.0.0/0', 'log' => true }])
          )
          allow_any_instance_of(CloudController::Blobstore::UrlGenerator).to receive(:droplet_download_url).and_return('www.droplet.url')
        end

        context 'with a buildpack backend' do
          let(:droplet) { DropletModel.make(:buildpack, package: package, app: app, buildpack_receipt_stack_name: 'potato-stack') }
          let(:package) { PackageModel.make(app: app) }

          let(:lifecycle_environment_variables) { [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'the-buildpack-env-var', value: 'the-buildpack-value')] }
          let(:lifecycle_cached_dependencies) { [::Diego::Bbs::Models::CachedDependency.new(
            from:      'http://file-server.service.cf.internal:8080/v1/static/potato_lifecycle_bundle_url',
            to:        '/tmp/lifecycle',
            cache_key: 'buildpack-potato-stack-lifecycle',
          )]
          }

          before do
            allow(recipe_builder).to receive(:envs_for_diego).with(app, task_details).and_return(lifecycle_environment_variables)
          end

          it 'constructs a TaskDefinition with app task instructions' do
            result = recipe_builder.build_app_task(config, task_details)
            expected_callback_url = "http://#{user}:#{password}@#{internal_service_hostname}:#{external_port}/internal/v3/tasks/#{task_details.guid}/completed"

            expect(result.log_guid).to eq(app.guid)
            expect(result.memory_mb).to eq(2048)
            expect(result.disk_mb).to eq(1024)
            expect(result.environment_variables).to eq(lifecycle_environment_variables)
            expect(result.root_fs).to eq('preloaded:potato-stack')
            expect(result.completion_callback_url).to eq(expected_callback_url)
            expect(result.privileged).to be(false)
            expect(result.egress_rules).to eq([
              rule_dns_everywhere,
              rule_http_everywhere
            ])
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
            expect(result.log_source).to eq('APP/TASK/potato-task')

            actions = result.action.serial_action.actions
            expect(actions.length).to eq(2)
            expect(actions[0].download_action).to eq(::Diego::Bbs::Models::DownloadAction.new(
                                                       from: 'www.droplet.url',
                                                       to: '.',
                                                       cache_key: '',
                                                       user: 'vcap',
                                                       checksum_algorithm: 'sha1',
                                                       checksum_value: droplet.droplet_hash,
            ))
            expect(actions[1].run_action).to eq(::Diego::Bbs::Models::RunAction.new(
                                                  user: 'vcap',
                                                  path: '/tmp/lifecycle/launcher',
                                                  args: ['app', 'bin/start', ''],
                                                  log_source: 'APP/TASK/potato-task',
                                                  env: lifecycle_environment_variables,
                                                  resource_limits: ::Diego::Bbs::Models::ResourceLimits.new
            ))
            expect(result.legacy_download_user).to eq('vcap')
            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)

            expect(result.metrics_guid).to eq('')
            expect(result.cpu_weight).to eq(25)
          end

          context 'when the blobstore_url_generator returns nil' do
            before do
              allow_any_instance_of(CloudController::Blobstore::UrlGenerator).to receive(:droplet_download_url).and_return(nil)
            end

            it 'returns an error' do
              expect {
                recipe_builder.build_app_task(config, task_details)
              }.to raise_error(
                VCAP::CloudController::Diego::RecipeBuilder::InvalidDownloadUri,
                /Failed to get blobstore download url for droplet #{droplet.guid}/
              )
            end
          end

          context 'when the requested stack is not in the configured lifecycle bundles' do
            let(:droplet) { DropletModel.make(:buildpack, package: package, app: app, buildpack_receipt_stack_name: 'leek-stack') }
            it 'returns an error' do
              expect {
                recipe_builder.build_app_task(config, task_details)
              }.to raise_error VCAP::CloudController::Diego::LifecycleBundleUriGenerator::InvalidStack
            end
          end

          describe 'volume mounts' do
            context 'when none are provided' do
              it 'is this even a thing?' do
              end
            end

            context 'when a volume mount is provided' do
              let(:service_instance) { ManagedServiceInstance.make space: app.space }
              let(:multiple_volume_mounts) do
                [
                  {
                    container_dir: '/data/images',
                    mode: 'r',
                    device_type: 'shared',
                    device: {
                      driver: 'cephfs',
                      volume_id: 'abc',
                      mount_config: {
                        key: 'value'
                      }
                    }
                  },
                  {
                    container_dir: '/data/scratch',
                    mode: 'rw',
                    device_type: 'shared',
                    device: {
                      driver: 'local',
                      volume_id: 'def',
                      mount_config: {}
                    }
                  }
                ]
              end

              before do
                ServiceBinding.make(app: app, service_instance: service_instance, volume_mounts: multiple_volume_mounts)
              end

              it 'desires the mount' do
                result = recipe_builder.build_app_task(config, task_details)
                expect(result.volume_mounts).to eq([
                  ::Diego::Bbs::Models::VolumeMount.new(
                    driver: 'cephfs',
                    container_dir: '/data/images',
                    mode: 'r',
                    shared: ::Diego::Bbs::Models::SharedDevice.new(volume_id: 'abc', mount_config: { 'key' => 'value' }.to_json),
                  ),
                  ::Diego::Bbs::Models::VolumeMount.new(
                    driver: 'local',
                    container_dir: '/data/scratch',
                    mode: 'rw',
                    shared: ::Diego::Bbs::Models::SharedDevice.new(volume_id: 'def', mount_config: ''),
                  ),
                ])
              end
            end
          end
        end
      end
    end
  end
end
