#!/usr/bin/env ruby

require 'cgi'
require 'date'
require 'yaml'

require 'git'

CONFIGFILE = 'config.yaml'
MAX_DESC_LENGTH = 33
MAX_SHORT_CMT_LENGTH = 33
MAX_COMMIT_TITLE_LENGTH = 83

class Wit
	def self.config
		YAML.load_file(CONFIGFILE)
	end

	def self.title
		conf = config
		conf[:title] ||= 'Wit'

		save_config_if_changed(conf)

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

		config[:groups].find { |h| h.has_key?(group) }[group][:repos].each_with_index do |repo_config, i|
			repo = self.new(group, repo_config.keys.first)
			repos.push(repo)
			yield(i % 2 == 0 ? 'odd' : 'even', repo) if(block_given?)
		end

		repos
	end

	def self.repo_info
		conf = config
		group, repo, show, start = cgi_params(conf)

		self.new(group, repo).repo_config.each do |key, val|
			yield(CGI.escapeHTML(key.to_s), CGI.escapeHTML(val)) if(block_given?)
		end
	end

	def self.repo_title
		conf = config
		group, repo, show, start = cgi_params(conf)

		yield(group, repo) if(block_given?)
		[group, repo]
	end

	def self.commits
		conf = config
		timefmt = conf[:commit_time_format] ||= '%Y/%m/%d'
		group, repo, show, start = cgi_params(conf)

		save_config_if_changed(conf)

		wit = self.new(group, repo)
		[wit.commits(show, start)].flatten.each_with_index do |commit, i|
			time = commit[:committer_time] ||commit[:author_time]
			time = time ? time.strftime(timefmt) : ''
			title = commit[:title]
			title = title[0..MAX_COMMIT_TITLE_LENGTH - 3] + '...' if(title && title.length > MAX_COMMIT_TITLE_LENGTH)
			info = time, commit[:author] || commit[:committer], title

			info.map { |c| CGI.escapeHTML(c || '') }
			yield(i % 2 == 0 ? 'odd' : 'even', *info)
		end
	end

	def self.next_page
		conf = config
		group, repo, show, start = cgi_params(conf)

		save_config_if_changed(conf)

		commits = self.new(group, repo).commits(show + 1, start)
		last = commits.is_a?(Array) ? commits.pop : commits
		if(commits.is_a?(Array) && last && commits && last[:hash] != commits.last[:hash])
			yield(group, repo, last[:hash]) if(block_given?)
			last[:hash]
		end
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
		desc.length > MAX_DESC_LENGTH ? desc[0..MAX_DESC_LENGTH - 3] + '...' : desc
	end

	def last_commit
		com = CGI.escapeHTML(commits[:title])
		com.length > MAX_SHORT_CMT_LENGTH ? com[0..MAX_SHORT_CMT_LENGTH - 3] + '...' : com
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
			yield(CGI.escapeHTML(key), CGI.escapeHTML(value)) if(block_given?)
		end

		config
	end

	def commits(num = 1, start = 'master')
		commits = []

		if(num > 0)
			ary = @git.rev_list('-n', num, '--pretty=raw', start).split("\n")
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

	def self.save_config_if_changed(conf)
		if(File.writable?(CONFIGFILE) && YAML.load_file(CONFIGFILE) != conf)
			File.open(CONFIGFILE, 'w') { |f| f.write(conf.to_yaml) }
		end
	end

	def self.cgi_params(conf)
		params = CGI.new.params

		[params['group'].first,
		 params['repo'].first,
		 (params['show'].first || conf[:commits_per_page] ||= 50).to_i,
		 params['start'].first || 'master']
	end

	def commitdata(ary)
		commit = { :hash => ary.shift.split.last,
		           :tree => ary.shift.split.last,
		           :parent => ary.shift.split.last }
		commit[:parent] = [commit[:parent]] if(ary.first.match(/^parent/))
		commit[:parent].push(ary.shift.split.last) while(ary.first.match(/^parent/))

		if(ary.empty?)
			author = nil
		else
			author = ary.first.match(/^author\s+(.+?)\s+<(.+?)>\s+(\d+)\s*(.*)$/)
			author = ary.first.match(/^author\s+()<(.+?)>\s+(\d+)\s*(.*)$/) unless(author)
		end
		if(author)
			ary.shift
			commit[:author], commit[:author_email] = author[1..2]
			commit[:author_time] = DateTime.strptime(author[3], '%s')#.new_offset(author[4].to_f / 24)
		end

		if(ary.empty?)
			committer = nil
		else
			committer = ary.first.match(/^committer\s+(.+?)\s+<(.+?)>\s+(\d+)\s*(.*)$/)
			committer = ary.first.match(/^committer\s+()<(.+?)>\s+(\d+)\s*(.*)$/) unless(committer)
		end
		if(committer)
			ary.shift
			commit[:committer], commit[:committer_email] = committer[1..2]
			commit[:committer_time] = DateTime.strptime(committer[3], '%s')#.new_offset(committer[4].to_f / 24)
		end

		commit[:title] = ary.shift unless(ary.empty? || ary.first.match(/^commit/))
		while(!ary.empty? && !ary.first.match(/^commit/))
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

		if(File.writable?(CONFIGFILE) && YAML.load_file(CONFIGFILE) != @config)
			File.open(CONFIGFILE, 'w') { |f| f.write(@config.to_yaml) }
		end
	end
end
