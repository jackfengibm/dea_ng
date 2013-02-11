require "tempfile"
require "tmpdir"
require "yaml"

require "vcap/staging"
require "dea/utils/download"
require "dea/utils/upload"
require "dea/promise"
require "dea/task"

module Dea
  class StagingTask < Task
    DROPLET_FILE = "droplet.tgz"
    STAGING_LOG = "staging_task.log"

    WARDEN_UNSTAGED_DIR = "/tmp/unstaged"
    WARDEN_STAGED_DIR = "/tmp/staged"
    WARDEN_STAGED_DROPLET = "/tmp/#{DROPLET_FILE}"
    WARDEN_CACHE = "/tmp/cache"
    WARDEN_STAGING_LOG = "#{WARDEN_STAGED_DIR}/logs/#{STAGING_LOG}"

    attr_reader :bootstrap, :dir_server, :attributes
    attr_reader :container_path

    def initialize(bootstrap, dir_server, attributes)
      super(bootstrap.config)
      @bootstrap = bootstrap
      @dir_server = dir_server
      @attributes = attributes.dup
    end

    def logger
      @logger ||= self.class.logger.tag({})
    end

    def task_id
      @task_id ||= VCAP.secure_uuid
    end

    def task_log
      File.read(staging_log_path) if File.exists?(staging_log_path)
    end

    def streaming_log_url
      @dir_server.url_for("/tasks/#{task_id}/file_path?path=#{WARDEN_STAGING_LOG}")
    end

    def start(&callback)
      staging_promise = Promise.new do |p|
        logger.info("<staging> Starting staging task")
        logger.info("<staging> Setting up temporary directories")
        logger.info("<staging> Working dir in #{workspace_dir}")

        resolve_staging_setup
        resolve_staging
        p.deliver
      end

      Promise.resolve(staging_promise) do |error, _|
        finish_task(error, &callback)
      end
    end

    def after_setup(&blk)
      @after_setup = blk
    end

    def trigger_after_setup(error)
      @after_setup.call(error) if @after_setup
    end
    private :trigger_after_setup

    def finish_task(error, &callback)
      callback.call(error) if callback
      clean_workspace
      raise(error) if error
    end

    def prepare_workspace
      StagingPlugin::Config.to_file({
        "source_dir"   => WARDEN_UNSTAGED_DIR,
        "dest_dir"     => WARDEN_STAGED_DIR,
        "environment"  => attributes["properties"]
      }, plugin_config_path)

      platform_config = staging_config["platform_config"]
      platform_config["cache"] = WARDEN_CACHE
      File.open(platform_config_path, "w") { |f| YAML.dump(platform_config, f) }
    end

    def promise_stage
      Promise.new do |p|
        script = "mkdir -p #{WARDEN_STAGED_DIR}/logs && "
        script += [staging_environment.map {|k, v| "#{k}=#{v}"}.join(" "),
                   config["dea_ruby"], run_plugin_path,
                   attributes["properties"]["framework_info"]["name"],
                   plugin_config_path, "> #{WARDEN_STAGING_LOG} 2>&1"].join(" ")
        logger.info("<staging> Running #{script}")

        begin
          promise_warden_run(:app, script).resolve
        ensure
          promise_task_log.resolve
        end
        p.deliver
      end
    end

    def promise_task_log
      Promise.new do |p|
        copy_out_request(WARDEN_STAGING_LOG, File.dirname(staging_log_path))
        logger.info "Staging task log: #{task_log}"
        p.deliver
      end
    end

    def promise_unpack_app
      Promise.new do |p|
        logger.info "<staging> Unpacking app to #{WARDEN_UNSTAGED_DIR}"
        script = "unzip -q #{downloaded_droplet_path} -d #{WARDEN_UNSTAGED_DIR}"
        promise_warden_run(:app, script).resolve

        p.deliver
      end
    end

    def promise_pack_app
      Promise.new do |p|
        script = "cd #{WARDEN_STAGED_DIR} && COPYFILE_DISABLE=true tar -czf #{WARDEN_STAGED_DROPLET} ."
        promise_warden_run(:app, script).resolve

        p.deliver
      end
    end

    def promise_app_download
      Promise.new do |p|
        logger.info("<staging> Downloading application from #{attributes["download_uri"]}")

        Download.new(attributes["download_uri"], workspace_dir).download! do |error, path|
          if !error
            File.rename(path, downloaded_droplet_path)
            File.chmod(0744, downloaded_droplet_path)

            logger.debug "<staging> Moved droplet to #{downloaded_droplet_path}"
            p.deliver
          else
            p.fail(error)
          end
        end
      end
    end

    def promise_app_upload
      Promise.new do |p|
        Upload.new(staged_droplet_path, attributes["upload_uri"]).upload! do |error|
          if !error
            logger.info("<staging> Uploaded app to #{attributes["upload_uri"]}")
            p.deliver
          else
            p.fail(error)
          end
        end
      end
    end

    def promise_copy_out
      Promise.new do |p|
        logger.info("Copying out to #{staged_droplet_path}")
        staged_droplet_dir = File.expand_path(File.dirname(staged_droplet_path))
        copy_out_request(WARDEN_STAGED_DROPLET, staged_droplet_dir)

        p.deliver
      end
    end

    def promise_container_info
      Promise.new do |p|
        raise ArgumentError, "container handle must not be nil" unless container_handle

        request = ::Warden::Protocol::InfoRequest.new(:handle => container_handle)
        response = promise_warden_call(:info, request).resolve

        raise RuntimeError, "container path is not available" \
          unless @container_path = response.container_path

        p.deliver(response)
      end
    end

    def path_in_container(path)
      File.join(container_path, path) if container_path
    end

    private

    def resolve_staging_setup
      prepare_workspace

      [ promise_app_download,
        promise_create_container,
      ].each(&:run).each(&:resolve)

      promise_container_info.resolve
      trigger_after_setup(nil)

    rescue => e
      trigger_after_setup(e)
      raise
    else
      trigger_after_setup(nil)
    end

    def resolve_staging
      [ promise_unpack_app,
        promise_stage,
        promise_pack_app,
        promise_copy_out,
        promise_app_upload,
        promise_destroy,
      ].each(&:resolve)
    end

    def runtime
      bootstrap.runtime(attributes["properties"]["runtime"], attributes["properties"]["runtime_info"])
    end

    def clean_workspace
      FileUtils.rm_rf(workspace_dir)
    end

    def paths_to_bind
      [workspace_dir, shared_gems_dir, File.dirname(staging_config["platform_config"]["insight_agent"])]
    end

    def workspace_dir
      return @workspace_dir if @workspace_dir
      staging_base_dir = File.join(config["base_dir"], "staging")
      @workspace_dir = Dir.mktmpdir(nil, staging_base_dir)
      File.chmod(0755, @workspace_dir)
      @workspace_dir
    end

    def shared_gems_dir
      @shared_gems_dir ||= staging_plugin_spec.base_dir
    end

    def staged_droplet_path
      @staged_droplet_path ||= File.join(workspace_dir, "staged", DROPLET_FILE)
    end

    def staging_log_path
      @staging_log_path ||= File.join(workspace_dir, STAGING_LOG)
    end

    def plugin_config_path
      @plugin_config_path ||= File.join(workspace_dir, "plugin_config")
    end

    def platform_config_path
      @platform_config_path ||= File.join(workspace_dir, "platform_config")
    end

    def downloaded_droplet_path
      @downloaded_droplet_path ||= File.join(workspace_dir, "app.zip")
    end

    def run_plugin_path
      @run_plugin_path ||= File.join(staging_plugin_spec.gem_dir, "bin", "run_plugin")
    end

    def staging_plugin_spec
      @staging_plugin_spec ||= Gem::Specification.find_by_name("vcap_staging")
    end

    def cleanup(file)
      file.close
      yield
    ensure
      File.unlink(file.path) if File.exist?(file.path)
    end

    def staging_environment
      {
        "GEM_PATH" => shared_gems_dir,
        "PLATFORM_CONFIG" => platform_config_path,
        "C_INCLUDE_PATH" => "#{staging_config["environment"]["C_INCLUDE_PATH"]}:#{ENV["C_INCLUDE_PATH"]}",
        "LIBRARY_PATH" => staging_config["environment"]["LIBRARY_PATH"],
        "LD_LIBRARY_PATH" => staging_config["environment"]["LD_LIBRARY_PATH"],
        "PATH" => "#{staging_config["environment"]["PATH"]}:#{ENV["PATH"]}"
      }
    end

    def staging_config
      config["staging"]
    end
  end
end