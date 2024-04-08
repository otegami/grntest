# Copyright (C) 2012-2024  Sutou Kouhei <kou@clear-code.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "rbconfig"
require "optparse"
require "pathname"

require "grntest/version"
require "grntest/test-suites-runner"

module Grntest
  class Tester
    class << self
      def run(argv=nil)
        argv ||= ARGV.dup
        tester = new
        catch do |tag|
          parser = create_option_parser(tester, tag)
          targets = parser.parse!(argv)
          tester.run(*targets)
        end
      end

      private
      def create_option_parser(tester, tag)
        parser = OptionParser.new
        parser.banner += " TEST_FILE_OR_DIRECTORY..."

        custom_groonga_httpd = false
        parser.on("--groonga=COMMAND",
                  "Use COMMAND as groonga command",
                  "(#{tester.groonga})") do |command|
          tester.groonga = normalize_command(command)
        end

        parser.on("--groonga-httpd=COMMAND",
                  "Use COMMAND as groonga-httpd command for groonga-httpd tests",
                  "(#{tester.groonga_httpd})") do |command|
          tester.groonga_httpd = normalize_command(command)
          custom_groonga_httpd = true
        end

        parser.on("--ngx-http-groonga-module-so=PATH",
                  "Use PATH as ngx_http_groonga_module.so for groonga-nginx tests",
                  "(#{tester.ngx_http_groonga_module_so})") do |path|
          tester.ngx_http_groonga_module_so = path
        end

        parser.on("--groonga-suggest-create-dataset=COMMAND",
                  "Use COMMAND as groonga_suggest_create_dataset command",
                  "(#{tester.groonga_suggest_create_dataset})") do |command|
          tester.groonga_suggest_create_dataset = normalize_command(command)
        end

        parser.on("--groonga-synonym-generate=COMMAND",
                  "Use COMMAND as groonga_synonym_generate command",
                  "(#{tester.groonga_synonym_generate})") do |command|
          tester.groonga_synonym_generate = normalize_command(command)
        end

        available_interfaces = ["stdio", "http"]
        available_interface_labels = available_interfaces.join(", ")
        parser.on("--interface=INTERFACE", available_interfaces,
                  "Use INTERFACE for communicating Groonga",
                  "[#{available_interface_labels}]",
                  "(#{tester.interface})") do |interface|
          tester.interface = interface
        end

        parser.on("--[no-]use-http-post",
                  "Use POST to send command by HTTP",
                  "(#{tester.use_http_post?})") do |boolean|
          tester.use_http_post = boolean
        end

        parser.on("--[no-]use-http-chunked",
                  "Use chunked Transfer-Encoding to send body by HTTP",
                  "(#{tester.use_http_chunked?})") do |boolean|
          tester.use_http_chunked = boolean
        end

        available_input_types = ["json", "apache-arrow"]
        available_input_type_labels = available_input_types.join(", ")
        parser.on("--input-type=TYPE", available_input_types,
                  "Use TYPE as the input type on load",
                  "[#{available_input_type_labels}]",
                  "(#{tester.input_type})") do |type|
          tester.input_type = type
        end

        available_output_types = ["json", "msgpack", "apache-arrow"]
        available_output_type_labels = available_output_types.join(", ")
        parser.on("--output-type=TYPE", available_output_types,
                  "Use TYPE as the output type",
                  "[#{available_output_type_labels}]",
                  "(#{tester.output_type})") do |type|
          tester.output_type = type
        end

        available_testees = ["groonga", "groonga-httpd", "groonga-nginx"]
        available_testee_labels = available_testees.join(", ")
        parser.on("--testee=TESTEE", available_testees,
                  "Test against TESTEE",
                  "[#{available_testee_labels}]",
                  "(#{tester.testee})") do |testee|
          tester.testee = testee
          case tester.testee
          when "groonga-httpd"
            tester.interface = "http"
          when "groonga-nginx"
            tester.interface = "http"
            tester.groonga_httpd = "nginx" unless custom_groonga_httpd
          end
        end

        parser.on("--base-directory=DIRECTORY",
                  "Use DIRECTORY as a base directory of relative path",
                  "(#{tester.base_directory})") do |directory|
          tester.base_directory = Pathname(directory)
        end

        parser.on("--database=PATH",
                  "Use existing database at PATH " +
                    "instead of creating a new database",
                  "(creating a new database)") do |path|
          tester.database_path = path
        end

        parser.on("--diff=DIFF",
                  "Use DIFF as diff command",
                  "Use --diff=internal to use internal differ",
                  "(#{tester.diff})") do |diff|
          tester.diff = diff
          tester.diff_options.clear
        end

        diff_option_is_specified = false
        parser.on("--diff-option=OPTION",
                  "Use OPTION as diff command",
                  "(#{tester.diff_options.join(' ')})") do |option|
          tester.diff_options.clear if diff_option_is_specified
          tester.diff_options << option
          diff_option_is_specified = true
        end

        available_reporters = [
          :mark,
          :"buffered-mark",
          :stream,
          :inplace,
          :progress,
          :"benchmark-json",
        ]
        available_reporter_labels = available_reporters.join(", ")
        parser.on("--reporter=REPORTER", available_reporters,
                  "Report test result by REPORTER",
                  "[#{available_reporter_labels}]",
                  "(auto)") do |reporter|
          tester.reporter = reporter
        end

        parser.on("--test=NAME",
                  "Run only test that name is NAME",
                  "If NAME is /.../, NAME is treated as regular expression",
                  "This option can be used multiple times") do |name|
          tester.test_patterns << parse_name_or_pattern(name)
        end

        parser.on("--test-suite=NAME",
                  "Run only test suite that name is NAME",
                  "If NAME is /.../, NAME is treated as regular expression",
                  "This option can be used multiple times") do |name|
          tester.test_suite_patterns << parse_name_or_pattern(name)
        end

        parser.on("--exclude-test=NAME",
                  "Exclude test that name is NAME",
                  "If NAME is /.../, NAME is treated as regular expression",
                  "This option can be used multiple times") do |name|
          tester.exclude_test_patterns << parse_name_or_pattern(name)
        end

        parser.on("--exclude-test-suite=NAME",
                  "Exclude test suite that name is NAME",
                  "If NAME is /.../, NAME is treated as regular expression",
                  "This option can be used multiple times") do |name|
          tester.exclude_test_suite_patterns << parse_name_or_pattern(name)
        end

        parser.on("--n-workers=N", Integer,
                  "Use N workers to run tests",
                  "(#{tester.n_workers})") do |n|
          tester.n_workers = n
        end

        parser.on("--gdb[=COMMAND]",
                  "Run Groonga on gdb and use COMMAND as gdb",
                  "(#{tester.default_gdb})") do |command|
          tester.gdb = command || tester.default_gdb
        end

        parser.on("--lldb[=COMMAND]",
                  "Run Groonga on lldb and use COMMAND as lldb",
                  "(#{tester.default_lldb})") do |command|
          tester.lldb = command || tester.default_lldb
        end

        parser.on("--rr[=COMMAND]",
                  "Run Groonga on 'rr record' and use COMMAND as rr",
                  "(#{tester.default_rr})") do |command|
          tester.rr = command || tester.default_rr
        end

        parser.on("--valgrind[=COMMAND]",
                  "Run Groonga on valgrind and use COMMAND as valgrind",
                  "(#{tester.default_valgrind})") do |command|
          tester.valgrind = command || tester.default_valgrind
        end

        parser.on("--[no-]valgrind-gen-suppressions",
                  "Generate suppressions for Valgrind",
                  "(#{tester.valgrind_gen_suppressions?})") do |boolean|
          tester.valgrind_gen_suppressions = boolean
        end

        parser.on("--[no-]keep-database",
                  "Keep used database for debug after test is finished",
                  "(#{tester.keep_database?})") do |boolean|
          tester.keep_database = boolean
        end

        parser.on("--[no-]stop-on-failure",
                  "Stop immediately on the first non success test",
                  "(#{tester.stop_on_failure?})") do |boolean|
          tester.stop_on_failure = boolean
        end

        parser.on("--no-suppress-omit-log",
                  "Suppress omit logs",
                  "(#{tester.suppress_omit_log?})") do |boolean|
          tester.suppress_omit_log = boolean
        end

        parser.on("--no-suppress-backtrace",
                  "Suppress backtrace",
                  "(#{tester.suppress_backtrace?})") do |boolean|
          tester.suppress_backtrace = boolean
        end

        parser.on("--output=OUTPUT",
                  "Output to OUTPUT",
                  "(stdout)") do |output|
          tester.output = File.open(output, "w:ascii-8bit")
        end

        parser.on("--[no-]use-color",
                  "Enable colorized output",
                  "(auto)") do |use_color|
          tester.use_color = use_color
        end

        parser.on("--timeout=SECOND", Float,
                  "Timeout for each test",
                  "(#{tester.timeout})") do |timeout|
          tester.timeout = timeout
        end

        parser.on("--read-timeout=SECOND", Float,
                  "Timeout for each read in test",
                  "(#{tester.read_timeout})") do |timeout|
          tester.read_timeout = timeout
        end

        parser.on("--[no-]debug",
                  "Enable debug information",
                  "(#{tester.debug?})") do |debug|
          tester.debug = debug
        end

        parser.on("--n-retries=N", Integer,
                  "Retry N times on failure",
                  "(#{tester.n_retries})") do |n|
          tester.n_retries = n
        end

        parser.on("--shutdown-wait-timeout=SECOND", Float,
                  "Timeout for waiting shutdown",
                  "(#{tester.shutdown_wait_timeout})") do |timeout|
          tester.shutdown_wait_timeout = timeout
        end

        parser.on("--random-seed=SEED", Integer,
                  "Seed for random numbers") do |seed|
          srand(seed)
        end

        parser.on("--[no-]benchmark",
                  "Set options for benchmark") do |benchmark|
          if benchmark
            tester.n_workers = 1
            tester.reporter = :"benchmark-json"
          end
        end

        parser.on("--version",
                  "Show version and exit") do
          puts(VERSION)
          throw(tag, true)
        end

        parser
      end

      def normalize_command(command)
        if File.executable?(command)
          return File.expand_path(command)
        end

        exeext = RbConfig::CONFIG["EXEEXT"]
        unless exeext.empty?
          command_exe = "#{command}#{exeext}"
          if File.executable?(command_exe)
            return File.expand_path(command_exe)
          end
        end

        command
      end

      def parse_name_or_pattern(name)
        if /\A\/(.+)\/\z/ =~ name
          Regexp.new($1, Regexp::IGNORECASE)
        else
          name
        end
      end
    end

    attr_accessor :groonga
    attr_accessor :groonga_httpd
    attr_accessor :ngx_http_groonga_module_so
    attr_accessor :groonga_suggest_create_dataset
    attr_accessor :groonga_synonym_generate
    attr_accessor :interface
    attr_writer :use_http_post
    attr_writer :use_http_chunked
    attr_accessor :input_type
    attr_accessor :output_type
    attr_accessor :testee
    attr_accessor :base_directory, :database_path, :diff, :diff_options
    attr_accessor :n_workers
    attr_accessor :output
    attr_accessor :gdb, :default_gdb
    attr_accessor :lldb, :default_lldb
    attr_accessor :rr, :default_rr
    attr_accessor :valgrind, :default_valgrind
    attr_accessor :timeout
    attr_accessor :read_timeout
    attr_writer :valgrind_gen_suppressions
    attr_writer :reporter, :keep_database, :use_color
    attr_writer :stop_on_failure
    attr_writer :suppress_omit_log
    attr_writer :suppress_backtrace
    attr_writer :debug
    attr_reader :test_patterns, :test_suite_patterns
    attr_reader :exclude_test_patterns, :exclude_test_suite_patterns
    attr_accessor :n_retries
    attr_accessor :shutdown_wait_timeout
    def initialize
      @groonga = "groonga"
      @groonga_httpd = "groonga-httpd"
      @ngx_http_groonga_module_so = nil
      @groonga_suggest_create_dataset = "groonga-suggest-create-dataset"
      unless command_exist?(@groonga_suggest_create_dataset)
        @groonga_suggest_create_dataset = nil
      end
      @groonga_synonym_generate = "groonga-synonym-generate"
      unless command_exist?(@groonga_synonym_generate)
        @groonga_synonym_generate = nil
      end
      @interface = "stdio"
      @use_http_post = false
      @use_http_chunked = false
      @input_type = "json"
      @output_type = "json"
      @testee = "groonga"
      @base_directory = Pathname(".")
      @database_path = nil
      @reporter = nil
      @n_workers = guess_n_cores
      @output = $stdout
      @keep_database = false
      @use_color = nil
      @stop_on_failure = false
      @suppress_omit_log = true
      @suppress_backtrace = true
      @debug = false
      @test_patterns = []
      @test_suite_patterns = []
      @exclude_test_patterns = []
      @exclude_test_suite_patterns = []
      detect_suitable_diff
      initialize_debuggers
      initialize_memory_checkers
      @timeout = 5
      @read_timeout = 3
      @n_retries = 0
      @shutdown_wait_timeout = 5
    end

    def run(*targets)
      succeeded = true
      return succeeded if targets.empty?

      test_suites = load_tests(*targets)
      run_test_suites(test_suites)
    end

    def reporter
      if @reporter.nil?
        if @n_workers == 1
          :mark
        else
          :progress
        end
      else
        @reporter
      end
    end

    def use_http_post?
      @use_http_post
    end

    def use_http_chunked?
      @use_http_chunked
    end

    def keep_database?
      @keep_database
    end

    def use_color?
      if @use_color.nil?
        @use_color = guess_color_availability
      end
      @use_color
    end

    def stop_on_failure?
      @stop_on_failure
    end

    def suppress_omit_log?
      @suppress_omit_log
    end

    def suppress_backtrace?
      @suppress_backtrace
    end

    def debug?
      @debug
    end

    def valgrind_gen_suppressions?
      @valgrind_gen_suppressions
    end

    def target_test?(test_name)
      selected_test?(test_name) and not excluded_test?(test_name)
    end

    def selected_test?(test_name)
      return true if @test_patterns.empty?
      @test_patterns.any? do |pattern|
        pattern === test_name
      end
    end

    def excluded_test?(test_name)
      @exclude_test_patterns.any? do |pattern|
        pattern === test_name
      end
    end

    def target_test_suite?(test_suite_name)
      selected_test_suite?(test_suite_name) and
        not excluded_test_suite?(test_suite_name)
    end

    def selected_test_suite?(test_suite_name)
      return true if @test_suite_patterns.empty?
      @test_suite_patterns.any? do |pattern|
        pattern === test_suite_name
      end
    end

    def excluded_test_suite?(test_suite_name)
      @exclude_test_suite_patterns.any? do |pattern|
        pattern === test_suite_name
      end
    end

    def plugins_directory
      groonga_path = Pathname(@groonga)
      unless groonga_path.absolute?
        groonga_path = Pathname(resolve_command_path(@groonga)).expand_path
      end
      base_dir = groonga_path.parent.parent
      installed_plugins_dir = base_dir + "lib" + "groonga" + "plugins"
      build_plugins_dir = base_dir + "plugins"
      if installed_plugins_dir.exist?
        installed_plugins_dir
      else
        build_plugins_dir
      end
    end

    private
    def load_tests(*targets)
      default_group_name = "."
      tests = {default_group_name => []}
      targets.each do |target|
        target_path = Pathname(target)
        next unless target_path.exist?
        target_path = target_path.cleanpath
        if target_path.directory?
          load_tests_under_directory(tests, target_path)
        else
          tests[default_group_name] << target_path
        end
      end
      tests
    end

    def load_tests_under_directory(tests, test_directory_path)
      test_file_paths = Pathname.glob(test_directory_path + "**" + "*.test")
      test_file_paths.each do |test_file_path|
        directory_path = test_file_path.dirname
        directory = directory_path.relative_path_from(test_directory_path).to_s
        tests[directory] ||= []
        tests[directory] << test_file_path
      end
    end

    def run_test_suites(test_suites)
      runner = TestSuitesRunner.new(self)
      runner.run(test_suites)
    end

    def guess_n_cores
      begin
        if command_exist?("nproc")
          # Linux
          Integer(`nproc`.strip, 10)
        elsif command_exist?("sysctl")
          # macOS
          Integer(`sysctl -n hw.logicalcpu`.strip, 10)
        else
          # Windows
          value = ENV["NUMBER_OF_PROCESSORS"]
          if value
            Integer(value, 10)
          else
            1
          end
        end
      rescue ArgumentError
        1
      end
    end

    def detect_suitable_diff
      if command_exist?("cut-diff")
        @diff = "cut-diff"
        @diff_options = ["--context-lines", "10"]
      elsif command_exist?("diff")
        @diff = "diff"
        @diff_options = ["-u"]
      else
        @diff = "internal"
        @diff_options = []
      end
    end

    def initialize_debuggers
      @gdb = nil
      @default_gdb = "gdb"
      @lldb = nil
      @default_lldb = "lldb"
      @rr = nil
      @default_rr = "rr"
    end

    def initialize_memory_checkers
      @vagrind = nil
      @default_valgrind = "valgrind"
      @vagrind_gen_suppressions = false
    end

    def resolve_command_path(name)
      exeext = RbConfig::CONFIG["EXEEXT"]
      ENV["PATH"].split(File::PATH_SEPARATOR).each do |path|
        raw_candidate = File.join(path, name)
        candidates = [
          raw_candidate,
          "#{raw_candidate}#{exeext}",
        ]
        candidates.each do |candidate|
          return candidate if File.executable?(candidate)
        end
      end
      nil
    end

    def command_exist?(name)
      not resolve_command_path(name).nil?
    end

    def guess_color_availability
      return false unless @output.tty?
      case ENV["TERM"]
      when /term(?:-(?:256)?color)?\z/, "screen"
        true
      else
        return true if ENV["EMACS"] == "t"
        false
      end
    end
  end
end
