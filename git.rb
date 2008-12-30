# encoding: utf-8

class Git
	attr_accessor(:git_dir)

	def initialize(git_bin, git_dir)
		@git_bin = git_bin
		@git_dir = File.expand_path(git_dir)
	end

	def method_missing(cmd, *opts)
		ret = `#{@git_bin} --git-dir='#{@git_dir}' #{cmd.to_s.gsub('_', '-')} #{opts.map {|str| quote(str.to_s)}.join(' ')} 2>&1`.chomp

		ret.force_encoding('binary') if(ret.respond_to?(:force_encoding))

		[ret, $?]
	end

	private

	def quote(str)
		str = "'#{str}'" unless str.match(/^['"].*['"]$/)

		str
	end
end
