#!/usr/bin/env ruby

class Git
	attr_accessor(:git_dir)

	def initialize(git_bin = 'git', git_dir = '.')
		@git_bin, @git_dir = git_bin, File.expand_path(git_dir)
	end

	def method_missing(cmd, *opts)
		`#{@git_bin} --git-dir='#{@git_dir}' #{cmd.to_s.gsub('_', '-')} #{opts.join(' ')}`
	end
end
