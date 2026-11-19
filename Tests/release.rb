#!/usr/bin/env ruby
# Exercise the publishing boundary without contacting Apple or GitHub.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

class ReleaseTest < Minitest::Test
	def setup
		@directory = Dir.mktmpdir('butter-release-', '/tmp')
		@repo = File.join(@directory, 'repo')
		@bin = File.join(@directory, 'bin')
		FileUtils.mkdir_p([File.join(@repo, 'Scripts'), @bin])
		FileUtils.cp(File.expand_path('../Scripts/release.sh', __dir__), File.join(@repo, 'Scripts'))
		@env = {
			'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'RELEASE_TEST_ROOT' => @directory,
			# Prevent Apple's rbconfig from invoking the mocked xcrun to locate an SDK.
			'SDKROOT' => ENV.fetch('SDKROOT', '/'),
			'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => '/dev/null',
			'GIT_AUTHOR_NAME' => 'Test', 'GIT_AUTHOR_EMAIL' => 'test@example.invalid',
			'GIT_COMMITTER_NAME' => 'Test', 'GIT_COMMITTER_EMAIL' => 'test@example.invalid'
		}
		git('init', '-q', '-b', 'main', @repo)
		git('-C', @repo, 'add', '.')
		git('-C', @repo, 'commit', '-qm', 'Fixture')
		git('-C', @repo, 'tag', '-a', 'v1.2.3', '-m', 'Fixture release')
		git('-C', @repo, 'remote', 'add', 'origin', 'git@github.com:Urethramancer/Butter.git')
		stub = File.join(@bin, 'stub')
		# Apple's /usr/bin/ruby launcher calls xcrun; bypass it inside the mocked PATH.
		File.write(stub, STUB.sub('#!/usr/bin/env ruby', "#!#{RbConfig.ruby}"))
		File.chmod(0755, stub)
		%w[git gh security xcrun xcodebuild codesign spctl ditto].each { |name| FileUtils.ln_s(stub, File.join(@bin, name)) }
	end

	def teardown
		FileUtils.remove_entry(@directory)
	end

	def git(*args)
		output, status = Open3.capture2e(@env, '/usr/bin/git', *args)
		assert status.success?, output
		output
	end

	def run_release(*args, failure: nil)
		@output, status = Open3.capture2e(@env.merge('RELEASE_TEST_FAILURE' => failure.to_s),
			'/bin/bash', File.join(@repo, 'Scripts/release.sh'), *args)
		@calls = File.exist?(File.join(@directory, 'calls')) ? File.readlines(File.join(@directory, 'calls')).map(&:strip) : []
		status.success?
	end

	def test_publish_only_after_stapling_and_download_verification
		assert run_release('v1.2.3'), @output
		operations = @calls.map { |line| line.split.first(2).join(' ') }
		assert_operator operations.index('xcrun staple'), :<, operations.rindex('ditto pack')
		assert_operator operations.index('xcrun validate'), :<, operations.index('git push')
		assert_operator operations.index('gh download'), :<, operations.index('gh edit')
		assert_includes @output, 'Published https://github.com/Urethramancer/Butter/releases/tag/v1.2.3'
		assert_empty Dir.glob(File.join(@repo, '.build/releases/*/source'))
	end

	def test_prepare_never_uses_github_or_pushes
		assert run_release('v1.2.3', '--prepare'), @output
		refute @calls.any? { |line| line.start_with?('gh ', 'git push') }
		checksums = Dir.glob(File.join(@repo, '.build/releases/*/SHA256SUMS'))
		assert_equal 1, checksums.size
		assert_match(/Butter-v1\.2\.3-arm64\.zip/, File.read(checksums.first))
	end

	def test_untagged_head_gets_version_and_commit_in_development_archive_name
		git('-C', @repo, 'commit', '-q', '--allow-empty', '-m', 'Development')
		revision = git('-C', @repo, 'rev-parse', '--short=12', 'HEAD').strip
		assert run_release('--prepare'), @output
		assets = Dir.glob(File.join(@repo, '.build/releases/*/Butter-*.zip'))
		assert_equal ["Butter-v1.2.3-dev-#{revision}-arm64.zip"], assets.map { |path| File.basename(path) }
		refute @calls.any? { |line| line.start_with?('gh ', 'git push') }
	end

	def test_tagged_head_uses_release_archive_name
		assert run_release('--prepare'), @output
		assets = Dir.glob(File.join(@repo, '.build/releases/*/Butter-*.zip'))
		assert_equal ['Butter-v1.2.3-arm64.zip'], assets.map { |path| File.basename(path) }
	end

	def test_failures_before_publication
		# Each condition must fail closed, including tools returning zero with an Invalid status.
		%w[credentials existing-release remote-tag version signature timestamp runtime debugging invalid notary-exit staple upload corrupt-download].each do |failure|
			FileUtils.rm_f(File.join(@directory, 'calls'))
			refute run_release('v1.2.3', failure: failure), "#{failure}: #{@output}"
			refute @calls.any? { |line| line.start_with?('gh edit') }, failure
			unless %w[upload corrupt-download].include?(failure)
				refute @calls.any? { |line| line.start_with?('git push', 'gh create') }, failure
			end
		end
	end

	def test_unannotated_or_malformed_tag_cannot_build
		git('-C', @repo, 'tag', 'v2.0.0')
		%w[v2.0.0 v01.2.3 main HEAD].each do |tag|
			refute run_release(tag), @output
			refute @calls.any? { |line| line.start_with?('xcodebuild ') }
		end
	end

	STUB = <<~'RUBY'
		#!/usr/bin/env ruby
		require 'fileutils'
		root = ENV.fetch('RELEASE_TEST_ROOT')
		failure = ENV.fetch('RELEASE_TEST_FAILURE', '')
		name = File.basename($0)
		log = ->(operation) { File.open(File.join(root, 'calls'), 'a') { |file| file.puts "#{name} #{operation}" } }
		identity = 'Developer ID Application: Ronny Bangsund (ZWL2A2VN43)'
		case name
		when 'git'
			if ARGV.first == 'ls-remote'
				puts "deadbeef\trefs/tags/v1.2.3" if failure == 'remote-tag'
			elsif ARGV.first == 'push'
				log.call('push')
			else
				exec '/usr/bin/git', *ARGV
			end
		when 'security'
			puts "1) ABCDEF \"#{identity}\""
		when 'xcodebuild'
			log.call(ARGV.include?('-exportArchive') ? 'export' : 'archive')
			if ARGV.include?('-exportArchive')
				app = File.join(ARGV[ARGV.index('-exportPath') + 1], 'Butter.app/Contents')
				FileUtils.mkdir_p(app)
				version = failure == 'version' ? '9.9.9' : '1.2.3'
				File.write(File.join(app, 'Info.plist'), "<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>#{version}</string><key>CFBundleIdentifier</key><string>net.grimdork.Butter</string></dict></plist>")
			end
		when 'codesign'
			if ARGV.include?('--entitlements')
				value = failure == 'debugging' ? 'true' : 'false'
				puts "<plist version=\"1.0\"><dict><key>com.apple.security.get-task-allow</key><#{value}/></dict></plist>"
			elsif ARGV.include?('-d')
				warn "Authority=#{failure == 'signature' ? 'Wrong' : identity}"
				warn 'TeamIdentifier=ZWL2A2VN43'
				warn 'CodeDirectory flags=0x10000(runtime)' unless failure == 'runtime'
				warn 'Timestamp=Nov 19, 2026' unless failure == 'timestamp'
			end
		when 'xcrun'
			operation = ARGV[1]
			log.call(operation)
			case operation
			when 'history'
				exit 1 if failure == 'credentials'
				puts '{}'
			when 'submit'
				puts "{\"id\":\"test-submission\",\"status\":\"#{failure == 'invalid' ? 'Invalid' : 'Accepted'}\"}"
				exit 1 if failure == 'notary-exit'
			when 'log'
				File.write(ARGV.last, '{}')
			when 'staple'
				exit 1 if failure == 'staple'
				File.write(File.join(ARGV.last, 'ticket'), 'stapled')
			end
		when 'ditto'
			log.call('pack')
			# Packing must preserve the distinction between pre- and post-stapled bundles.
			File.write(ARGV.last, File.exist?(File.join(ARGV[-2], 'ticket')) ? 'stapled zip' : 'submission zip')
		when 'gh'
			operation = ARGV.first == 'release' ? ARGV[1] : ARGV.first
			log.call(operation)
			case operation
			when 'api'
				puts 'v1.2.3' if failure == 'existing-release'
			when 'create'
				exit 1 if failure == 'upload'
				raise 'must create draft' unless ARGV.include?('--draft') && ARGV.include?('--verify-tag')
				FileUtils.mkdir_p(File.join(root, 'uploaded'))
				ARGV.select { |arg| File.file?(arg) }.each { |asset| FileUtils.cp(asset, File.join(root, 'uploaded')) }
			when 'download'
				destination = ARGV[ARGV.index('--dir') + 1]
				FileUtils.cp(Dir.glob(File.join(root, 'uploaded/*')), destination)
				if failure == 'corrupt-download'
					File.write(Dir.glob(File.join(destination, '*.zip')).first, 'corrupted')
				end
			end
		when 'spctl'
			log.call('assess')
		else
			raise "Unexpected tool #{name}"
		end
	RUBY
end
