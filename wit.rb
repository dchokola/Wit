#!/usr/bin/env ruby

require 'cgi'
require 'date'
require 'yaml'

require 'git'

CONFIGFILE = 'config.yaml'
MAX_TEXT_LENGTH = 33

class Wit
	def self.config
		YAML.load_file(CONFIGFILE)
	end

	def self.title
		conf = config
		conf[:title] ||= 'Wit'

		File.open(CONFIGFILE, 'w+') do |f|
			cfg = conf.to_yaml
			f.write(cfg) if(f.read != cfg)
		end if(File.writable?(CONFIGFILE))

		CGI.escapeHTML(conf[:title])
	end

	def self.groups
		groups = []

		config[:groups].each do |group_config|
			group = group_config.keys.first
			groups.push(group)
			yield(group) if(block_given?)
		end

		groups
	end

	def self.repos(group)
		repos = []

		config[:groups].find { |h| h.has_key?(group) }[group][:repos].each do |repo_config|
			repo = self.new(group, repo_config.keys.first)
			repos.push(repo)
			yield(repo) if(block_given?)
		end

		repos
	end

	attr_reader(:config, :group, :name)

	def initialize(group, name)
		@config = YAML.load_file(File.expand_path(CONFIGFILE))
		@group, @name = group, name
		@repoconfig = @config[:groups].find do |g|
			g.has_key?(@group)
		end[@group][:repos].find { |h| h.has_key?(@name) }[@name]
		@git = Git.new(@repoconfig[:path])
	end

	def description
		desc = CGI.escapeHTML(@repoconfig[:description] ||= '')
		desc.length > MAX_TEXT_LENGTH ? desc[0..MAX_TEXT_LENGTH - 3] + '...' : desc
	end

	def last_commit
		com = CGI.escapeHTML(commits[:title])
		com.length > MAX_TEXT_LENGTH ? com[0..MAX_TEXT_LENGTH - 3] + '...' : com
	end

	def owner
		CGI.escapeHTML(@repoconfig[:owner] ||= repo_config[:'user.name'])
	end

	def last_update
		difference = ((DateTime.now - commits[:committer_time]).to_f * 24 * 60 * 60).to_i

		if(difference < div = 60)
			'right now'
		elsif(difference < (div = 60) * 60)
			time = difference / div
			"#{time} minute#{time > 1 ? 's' : ''} ago"
		elsif(difference < (div = 60 * 60) * 24)
			time = difference / div
			"#{time} hour#{time > 1 ? 's' : ''} ago"
		elsif(difference < (div = 60 * 60 * 24) * 7)
			time = difference / div
			"#{time} day#{time > 1 ? 's' : ''} ago"
		elsif(difference < (div = 60 * 60 * 24 * 7) * (30.0 / 7))
			time = difference / div
			"#{time} week#{time > 1 ? 's' : ''} ago"
		elsif(difference < (div = 60 * 60 * 24 * 30) * (365.0 / 30))
			time = difference / div
			"#{time} month#{time > 1 ? 's' : ''} ago"
		else
			time = difference / (60 * 60 * 365 * 24)
			"#{time} year#{time > 1 ? 's' : ''} ago"
		end
	end

	def repo_config
		config = {}

		@git.repo_config('--list').split("\n").each do |prop|
			key, value = prop.split('=')
			config[key.to_sym] = value
			yield(CGI.excapeHTML(key), CGI.excapeHTML(value)) if(block_given?)
		end

		config
	end

	def commits(num = 1, start = 'master')
		commits = []

		if(num > 0)
			ary = @git.rev_list('-n', '1', '--pretty=raw', start).split("\n")
		else
			ary = @git.rev_list('--pretty=raw', start).split("\n")
		end
		ary = ary.map { |s| s.strip }.delete_if { |a| a.nil? || a.empty? }

		while(!ary.empty?)
			commits.push(commitdata(ary))
		end

		commits.length == 1 ? commits.first : commits
	end

	def branches
		@git.branch.split("\n").map { |b| b.sub(/\*/, '').lstrip }
	end

	def close
		save_config
	end

	private

	def commitdata(ary)
		commit = { :hash => ary.shift.split.last,
		           :tree => ary.shift.split.last,
		           :parent => ary.shift.split.last
		}

		author = ary.first.match(/^author\s+(.+?)\s+<(.+?)>\s+(\d+)\s*(.*)$/i) unless(ary.empty?)
		if(author)
			ary.shift
			commit[:author], commit[:author_email] = author[1..2]
			commit[:author_time] = DateTime.strptime(author[3], '%s').new_offset(author[4].to_i)
		end

		committer = ary.first.match(/^committer\s+(.+?)\s+<(.+?)>\s+(\d+)\s*(.*)$/i) unless(ary.empty?)
		if(committer)
			ary.shift
			commit[:committer], commit[:committer_email] = committer[1..2]
			commit[:committer_time] = DateTime.strptime(committer[3], '%s').new_offset(committer[4].to_i)
		end

		commit[:title] = ary.shift unless(ary.empty?)
		while(!ary.empty? && !ary.first.match(/^commit/i))
			commit[:description] = [commit[:description], ary.shift].join(' ')
		end
		commit[:description].lstrip if(commit[:description])

		commit
	end

	def save_config
		g, r = 0, 0

		@config[:groups].each_with_index { |grp, i| g = i if(grp.keys.first == @group) }
		@config[:groups][g][@group][:repos].each_with_index { |repo, i| r = i if(repo.keys.first == @name) }

		@config[:groups][g][@group][:repos][r][@name] = @repoconfig

		File.open(CONFIGFILE, 'w+') do |f|
			conf = @config.to_yaml
			f.write(conf) if(f.read != conf)
		end if(File.writable?(CONFIGFILE))
	end
end
