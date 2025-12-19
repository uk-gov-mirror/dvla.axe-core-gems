require "forwardable"
require "json"

require_relative "../../chain_mail/chainable"
require_relative "./audit"
require_relative "./context"
require_relative "./options"
require_relative "./results"
require_relative "../core"

module Axe
  module API
    class Run
      JS_NAME = "run"
      METHOD_NAME = "#{Core::JS_NAME}.#{JS_NAME}"

      extend Forwardable
      def_delegators :@context, :within, :excluding
      def_delegators :@options, :according_to, :checking, :checking_only, :skipping, :with_options

      extend ChainMail::Chainable
      chainable :within, :excluding, :according_to, :checking, :checking_only, :skipping, :with_options

      def initialize
        @context = Context.new
        @options = Options.new
      end

      def call(page)
        results = audit page
        Audit.new(to_js, Results.new(results))
      end

      def analyze_post_43x(page, lib)
        puts "Entering analyze_post_43x"

        start = Time.now
        user_page_load = nil

        unless is_cuprite?(page)
          driver = get_driver(page)

          user_page_load = driver.manage.timeouts.page_load
          driver.manage.timeouts.page_load = 1
        end

        begin
          @original_window = window_handle page
          partial_results = run_partial_recursive(page, @context, lib, true)
          throw partial_results if partial_results.respond_to?("key?") and partial_results.key?("errorMessage")

          results = within_about_blank_context(page) { |page|
            partial_res_str = partial_results.to_json
            size_limit = 10_000_000

            while not partial_res_str.empty? do
              chunk_size = size_limit
              chunk_size = partial_res_str.length if chunk_size > partial_res_str.length
              chunk = partial_res_str[0..chunk_size-1]
              partial_res_str = partial_res_str[chunk_size..-1]
              store_chunk page, chunk
            end

            Common::Loader.new(page, lib).load_top_level Axe::Configuration.instance.jslib
            begin
              axe_finish_run page
            rescue
              raise StandardError.new "axe.finishRun failed. Please check out https://github.com/dequelabs/axe-core-gems/blob/develop/error-handling.md"
            end
          }
        ensure
          (get_driver page).manage.timeouts.page_load = user_page_load unless user_page_load.nil?
        end

        puts "Exiting analyze_post_43x after #{Time.now - start} seconds"

        Audit.new to_js, Results.new(results)
      end

      private

      def audit(page)
        script = <<-JS
          var callback = arguments[arguments.length - 1];
          var context = arguments[0] || document;
          var options = arguments[1] || {};
          #{METHOD_NAME}(context, options).then(res => JSON.parse(JSON.stringify(res))).then(callback);
        JS

        page.execute_async_script_fixed(script, *js_args)
      end

      def switch_to_frame_by_handle(page, handle)
        return frame(handle) if is_cuprite?(page)

        page = get_driver(page)
        page.switch_to.frame(handle)
      end

      def frame(handle)
        return handle.frame if handle.respond_to?(:frame)

        handle
      end

      def switch_to_parent_frame(page)
        return page.switch_to_frame(:parent) if is_cuprite?(page)

        page = get_driver page
        page.switch_to.parent_frame
      end

      def within_about_blank_context(page)
        puts "Entering within_about_blank_context"
        start = Time.now

        driver = get_driver page
        is_cuprite = is_cuprite?(page)

        # This is a workaround to maintain Selenium 3 support
        # Likely driver.switch_to.new_window(:tab) should be used instead, should we drop support, as per
        # https://github.com/dequelabs/axe-core-gems/issues/352

        before_handles = page.window_handles
        begin
          script = "window.open('about:blank', '_blank')"
          is_cuprite ? driver.execute(script) : driver.execute_script(script)
        rescue
          raise StandardError.new "switchToWindow failed. Are you using updated browser drivers? Please check out https://github.com/dequelabs/axe-core-gems/blob/develop/error-handling.md"
        end

        new_handle = page.window_handles.difference(before_handles).first
        raise StandardError.new("Unable to determine window handle") if new_handle.nil?

        if is_cuprite
          start = Time.now
          driver.switch_to_window new_handle
          puts "switch_to_window took #{Time.now - start} seconds"

          ret = yield page

          driver.close_window new_handle
          driver.switch_to_window @original_window
        else
          driver.switch_to.window new_handle
          driver.get "about:blank"

          ret = yield page

          driver.switch_to.window new_handle
          driver.close
          driver.switch_to.window @original_window
        end

        puts "Exiting within_about_blank_context after #{Time.now - start} seconds"

        ret
      end

      def window_handle(page)
        page = get_driver page

        return page.window_handle if page.respond_to?(:window_handle)
        return page.current_window_handle if page.respond_to?(:current_window_handle)
        return page.id if page.respond_to?(:id)

        raise StandardError.new "Unable to determine window handle"
      end

      def run_partial_recursive(page, context, lib, top_level = false, frame_stack = [])
        puts "Entering run_partial_recursive (top_level=#{top_level}, frame_stack size=#{frame_stack.size})"
        start = Time.now

        begin
          current_window_handle = window_handle page
          if not top_level
            begin
              # Injects the axe-core library into the frame context
              Common::Loader.new(page, lib).load_top_level Axe::Configuration.instance.jslib
            rescue
              return [nil]
            end
          end

          frame_contexts = get_frame_context_script(page)
          if frame_contexts.respond_to?("key?") and frame_contexts.key?("errorMessage")
            throw frame_contexts if top_level
            return [nil]
          end

          res = axe_run_partial(page, context)

          if res.nil? || res.key?("errorMessage")
            if top_level
              throw res unless res.nil?
              throw "axe.runPartial returned null"
            end
            return [nil]
          else
            results = [res]
          end

          for frame_context in frame_contexts
            begin
              frame_selector = frame_context["frameSelector"]
              frame_context = frame_context["frameContext"]
              frame_handle = axe_shadow_select(page, frame_selector)

              if is_cuprite?(page)
                frame = frame(frame_handle)
                res = run_partial_recursive(frame, frame_context, lib, false, [*frame_stack, frame])
                results += res
              else
                switch_to_frame_by_handle(page, frame_handle)
                res = run_partial_recursive(page, frame_context, lib, false, [*frame_stack, frame_handle])
                results += res
              end
            rescue Selenium::WebDriver::Error::TimeoutError
              # Selenium approach: need to restore frame context by replaying frame_stack
              page = get_driver page
              page.switch_to.window current_window_handle
              frame_stack.each { |frame| page.switch_to.frame frame }
              results.push nil
            rescue Ferrum::TimeoutError
              # Cuprite approach: frame is a separate object, no context restoration needed
              results.push nil
            end
          end
        ensure
          switch_to_parent_frame(page) if not top_level and not is_cuprite?(page)
        end

        puts "Exiting run_partial_recursive after #{Time.now - start} seconds"

        return results
      end

      def store_chunk(page, chunk)
        start = Time.now
        script = <<-JS
          const chunk = arguments[0];
          window.partialResults ??= '';
          window.partialResults += chunk;
        JS

        result = page.execute_script_fixed(script, chunk)
        puts "store_chunk took #{Time.now - start} seconds"
        result
      end

      def axe_finish_run(page)
        start = Time.now
        result = is_cuprite?(page) ? axe_finish_run_cuprite(page) : axe_finish_run_selenium(page)
        puts "axe_finish_run took #{Time.now - start} seconds"
        result
      end

      def axe_finish_run_cuprite(page)
        script = <<-JS
          const cb = arguments[arguments.length - 1];
          const partialResults = JSON.parse(window.partialResults || '[]');

          axe.finishRun(partialResults).then(result => cb(JSON.stringify(result))).catch(() => cb(null));
        JS

        JSON.parse(page.execute_async_script_fixed(script))
      rescue JSON::ParserError, TypeError
        nil
      end

      def axe_finish_run_selenium(page)
        script = <<-JS
          const partialResults = JSON.parse(window.partialResults || '[]');
          return axe.finishRun(partialResults);
        JS
        page.execute_script_fixed script
      end

      def axe_shadow_select(page, frame_selector)
        start = Time.now
        script = <<-JS
          const frameSelector = arguments[0];
          return axe.utils.shadowSelect(frameSelector);
        JS

        result = page.execute_script_fixed(script, frame_selector)
        puts "axe_shadow_select took #{Time.now - start} seconds"
        result
      end

      def axe_run_partial(page, context)
        start = Time.now
        result = is_cuprite?(page) ? axe_run_partial_cuprite(page, context) : axe_run_partial_selenium(page, context)
        puts "axe_run_partial took #{Time.now - start} seconds"
        result
      end

      def axe_run_partial_cuprite(page, context)
        script = <<-JS
          const context = arguments[0];
          const options = arguments[1];
          const cb = arguments[arguments.length - 1];

          axe.runPartial(context, options)
             .then(res => { cb(JSON.stringify(res)) })
             .catch(err => cb(JSON.stringify({
               violations: [],
               passes: [],
               url: '',
               timestamp: new Date().toString(),
               errorMessage: err.message
             })));
        JS


        return JSON.parse(page.execute_async_script_fixed(script, context, @options)) if page.respond_to?(:execute_async_script_fixed)
        return JSON.parse(page.evaluate_async(script, 2, context, @options)) if page.respond_to?(:evaluate_async)

        raise StandardError.new "The page object does not support async script execution"
      rescue JSON::ParserError, TypeError
        nil
      end

      def axe_run_partial_selenium(page, context)
        script = <<-JS
          const context = arguments[0];
          const options = arguments[1];
          const cb = arguments[arguments.length - 1];
          try {
            const ret = window.axe.runPartial(context, options).then(res => JSON.parse(JSON.stringify(res)));
            cb(ret);
          } catch (err) {
            const ret = {
              violations: [],
              passes: [],
              url: '',
              timestamp: new Date().toString(),
              errorMessage: err.message
            };
            cb(ret);
          }
        JS
        page.execute_async_script_fixed script, context, @options
      end

      def get_frame_context_script(page)
        start = Time.now
        script = <<-JS
          const context = arguments[0];
          try {
            return window.axe.utils.getFrameContexts(context);
          } catch (err) {
            return {
              violations: [],
              passes: [],
              url: '',
              timestamp: new Date().toString(),
              errorMessage: err.message
            };
          }
        JS

        result = page.execute_script_fixed(script, @context) if page.respond_to?(:execute_script_fixed)
        result = page.evaluate_func(wrap(script, @context), @context) if page.respond_to?(:evaluate_func)

        puts "get_frame_context_script took #{Time.now - start} seconds"

        return result unless result.nil?

        raise StandardError.new "The page object does not support script execution"
      end

      def get_driver(page)
        page = page.driver if page.respond_to?("driver")
        page = page.browser if page.respond_to?("browser") and not page.browser.is_a?(::Symbol)
        page
      end

      def is_cuprite?(page)
        return @is_cuprite if defined?(@is_cuprite)

        driver = get_driver(page)
        @is_cuprite = driver.respond_to?(:evaluate_func) && driver.respond_to?(:evaluate_async)
      end

      def js_args
        [@context, @options]
          .map(&:to_h)
      end

      def to_js
        str_args = (js_args + ["callback"]).join(", ")
        "#{METHOD_NAME}(#{str_args});"
      end

      def wrap(script, *args)
        args = args.each_with_index.map { |_arg, index| "arg_#{index}" }.join(", ")

        "(function(#{args}) { #{script} })"
      end
    end
  end
end
