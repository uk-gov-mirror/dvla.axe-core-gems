require_relative "./axe/configuration"
require_relative "./axe/core"
require_relative "./hooks"

module Common
  class Loader
    def initialize(page, lib)
      @page = page
      @lib = lib
      @loaded_top_level = false
    end

    def load_top_level(source)
      respond_to_execute_script? ? @page.execute_script(source) : @page.execute(source)
      @loaded_top_level = true
      Common::Hooks.run_after_load @lib
    end

    def call(source, is_top_level = true)
      unless (@loaded_top_level and is_top_level)
        respond_to_execute_script? ? @page.execute_script(source) : @page.execute(source)
      end

      set_allowed_origins
      Common::Hooks.run_after_load @lib
      load_into_iframes(source) unless Axe::Configuration.instance.skip_iframes
    end

    private

    def set_allowed_origins
      allowed_origins = "<same_origin>"
      allowed_origins = "<unsafe_all_origins>" if !Axe::Configuration.instance.legacy_mode && !Axe::Core::has_run_partial?(@page)

      script = "axe.configure({ allowedOrigins: ['#{allowed_origins}'] });"

      respond_to_execute_script? ? @page.execute_script(script) : @page.execute(script)
    end

    def load_into_iframes(source)
      @page.find_frames.each do |iframe|
        @page.within_frame(iframe) { call source, false }
      end
    end

    def respond_to_execute_script?
      @page.respond_to?(:execute_script)
    end
  end
end
