require_relative "../../lib/webdriver_script_adapter/execute_async_script_adapter"

module WebDriverScriptAdapter
  describe ExecuteAsyncScriptAdapter do
    subject { described_class.new driver }
    let(:driver) { spy("driver") }

    describe "#execute_async_script" do
      it "should delegate to #execute_script" do
        subject.execute_async_script :foo
        expect(driver).to have_received(:execute_script)
      end

      it "should wrap the script in an anonymous function" do
        subject.execute_async_script :foo
        expect(driver).to have_received(:execute_script).with a_string_starting_with "(function(){ foo })"
      end

      it "should pass along provided arguments to the anonymous function (unescaped for now)" do
        subject.execute_async_script :foo, :a, 1, "2"
        expect(driver).to have_received(:execute_script).with a_string_matching "(a, 1, 2)"
      end

      it "should pass a callback as the last argument" do
        subject.execute_async_script :foo
        expect(driver).to have_received(:execute_script).with a_string_matching(/function\(err, returnValue\){ window\['.*'\] = \(err \|\| returnValue\); \}\)/)
      end

      it "should attempt to evaluate the stored async results" do
        subject.execute_async_script :foo
        expect(driver).to have_received(:evaluate_script).with a_string_matching(/window\['.*'\]/)
      end

      context "with configured result identifier" do
        before :each do
          WebDriverScriptAdapter.configure do |c|
            c.async_results_identifier = -> { :foo }
          end
        end

        it "should use the configured result identifier in the callback" do
          subject.execute_async_script :foo
          expect(driver).to have_received(:execute_script).with a_string_ending_with "function(err, returnValue){ window['foo'] = (err || returnValue); });"
        end

        it "should use the configured result identifier in the callback" do
          subject.execute_async_script :foo
          expect(driver).to have_received(:evaluate_script).with "window['foo']"
        end
      end

      it "should return the final evaluated results" do
        allow(driver).to receive(:evaluate_script).and_return(:foo)
        expect(subject.execute_async_script :bar).to be :foo
      end

      it "should treat `false` as a valid return value" do
        allow(driver).to receive(:evaluate_script).and_return(false)
        expect(subject.execute_async_script :foo).to be false
      end

      it "should retry until the results are ready", :slow do
        nil_invocations = Array.new(5, nil)
        allow(driver).to receive(:evaluate_script).and_return(*nil_invocations, :foo)
        expect(subject.execute_async_script :bar).to be :foo
      end

      it "should timeout if results aren't ready after some time", :slow do
        allow(driver).to receive(:evaluate_script) { sleep(5) and :foo }
        expect { subject.execute_async_script :bar }.to raise_error Timeout::Error
      end
    end

    describe '#execute_async_script_fixed' do
      context 'Cuprite' do
        let(:browser) { spy("browser") }
        let(:driver) { spy("driver", browser:) }

        before do
          allow(browser).to receive(:class).and_return(double(name: "Some::Cuprite::Class"))
          allow(browser).to receive(:evaluate_async).and_return(:foo)
        end

        it 'passes a 1 second timeout to evaluate_async' do
          subject.execute_async_script_fixed :bar
          expect(browser).to have_received(:evaluate_async).with(:bar, 1)
        end

        it 'should call execute_async_script on the underlying browser' do
          subject.execute_async_script_fixed :bar, 1, 2
          expect(browser).to have_received(:evaluate_async).with(:bar, 1, 1, 2)
        end
      end

      context 'not Cuprite' do
        it 'should call execute_async_script on the underlying driver' do
          subject.execute_async_script_fixed :foo, 1, 2
          expect(driver).to have_received(:execute_async_script).with(:foo, 1, 2)
        end
      end
    end
  end
end
