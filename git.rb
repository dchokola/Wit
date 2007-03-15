#!/usr/bin/env ruby

class Git
	attr_accessor(:git_dir)

	def initialize(git_dir = '.')
		@git_dir = File.expand_path(git_dir)
	end

	def method_missing(cmd, *opts)
		`git --git-dir='#{@git_dir}' #{cmd.to_s.gsub('_', '-')} #{opts.join(' ')}`
	end
end
