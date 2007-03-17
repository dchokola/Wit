require 'cgi'
require 'yaml'

require 'git'

CONFIGFILE = 'config.yaml'
MAX_DESC_LENGTH = 33
MAX_SHORT_CMT_LENGTH = 33
MAX_COMMIT_TITLE_LENGTH = 83

class Wit
	CONFIG = YAML.load_file(CONFIGFILE)

	# some default values
	CONFIG[:title] ||= "Puzzles' Wit"
	CONFIG[:commit_time_format] ||= '%Y/%m/%d %H:%M:%S'
	CONFIG[:git_bin] ||= 'git'
	CONFIG[:tab_width] ||= 4
	CONFIG[:commits_per_page] ||= 50

	def self.title
		CGI.escapeHTML(CONFIG[:title])
	end

	def self.groups
		CONFIG[:groups].each do |group|
			yield(group[:name]) if(block_given?)
		end
	end

	def self.repos(group)
		repos = []

		CONFIG[:groups].find { |h| h[:name] == group }[:repos].each_with_index do |repo, i|
			repo = new(group, repo[:name])
			repos.push(repo)
			yield(i % 2 == 0 ? 'odd' : 'even', repo) if(block_given?)
		end

		repos
	end

	def self.repo_info
		group, repo, show, start, branch = cgi_params
		wit = new(group, repo)

		{ 'Group' => group,
		  'Name' => repo,
		  'Description' => wit.repoconfig[:description],
		  'Last modified' => wit.last_update }.each do |key, val|
			yield(CGI.escapeHTML(key.to_s), CGI.escapeHTML(val)) if(block_given?)
		end
	end

	def self.repo_title
		group, repo, show, start, branch = cgi_params

		yield(group, repo, branch) if(block_given?)
		[group, repo, branch]
	end

	def self.commits
		timefmt = CONFIG[:commit_time_format]
		group, repo, show, start, branch = cgi_params

		wit = new(group, repo)
		[wit.commits(show, start)].flatten.each_with_index do |commit, i|
			time = commit[:committer_time] || commit[:author_time]
			time = time ? time.utc.strftime(timefmt) : ''
			title = commit[:title]
			title = title[0..MAX_COMMIT_TITLE_LENGTH - 3] + '...' if(title && title.length > MAX_COMMIT_TITLE_LENGTH)
			info = time, commit[:author] || commit[:committer], title

			info.map { |c| CGI.escapeHTML(c || '') }
			yield(group, repo, branch, commit[:hash], commit[:parent], i % 2 == 0 ? 'odd' : 'even', *info)
		end
	end

	def self.branches
		group, repo, show, start, branch = cgi_params

		new(group, repo).branches.each_with_index do |branch, i|
			yield(i % 2 == 0 ? 'odd' : 'even', group, repo, CGI.escapeHTML(branch))
		end
	end

	def self.next_page
		group, repo, show, start, branch = cgi_params

		commits = new(group, repo).commits(show + 1, start)
		last = commits.is_a?(Array) ? commits.pop : commits
		if(commits.is_a?(Array) && last && commits && last[:hash] != commits.last[:hash])
			yield(group, repo, last[:hash]) if(block_given?)
			last[:hash]
		end
	end

	def self.diff
		params = CGI.new.params
		group = params['group'].first
		repo =  params['repo'].first
		wit = new(group, repo)
		head = params['head'].first
		parent = params['parent'].first || [wit.commits(1, head)[:parent]].flatten.first

		ret = wit.diff(head, parent).map do |line|
			style = 'diff'
			case(line)
				when(/^@/)
					style = 'purple'
				when(/^\+/)
					style = 'green'
				when(/^-/)
					style = 'red'
			end

			line = CGI.escapeHTML(line)
			line.gsub!(/\t/, ' ' * CONFIG[:tab_width])
			yield(style, line) if(block_given?)
		end

		ret
	end

	def self.commit_info
		params = CGI.new.params
		group = params['group'].first
		repo =  params['repo'].first
		head = params['head'].first
		timefmt = CONFIG[:commit_time_format]

		Wit.new(group, repo).commits(1, head).sort { |a, b| a.to_s <=> b.to_s }.each do |prop|
			(key, val) = prop
			val = val.strftime(timefmt) if(key == :committer_time || key == :author_time)
			val.sub!('@', ' at ') if(key == :committer_email || key == :author_email)
			yield(CGI.escapeHTML(key.to_s), CGI.escapeHTML(val.to_s)) if(block_given?)
		end
	end

	attr_reader(:repoconfig, :group, :name)

	def initialize(group, name)
		@group, @name = group, name
		@repoconfig = CONFIG[:groups].find { |g| g[:name] == @group }[:repos].find { |h| h[:name] == @name }
		@git = Git.new(CONFIG[:git_bin], @repoconfig[:path])
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
		difference = (Time.now - commits[:committer_time]).to_i

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

	def diff(head, parent)
		@git.diff(parent || head, head).split("\n") || []
	end

	def close
		save_config
	end

	private

	def self.cgi_params
		params = CGI.new.params

		[params['group'].first,
		 params['repo'].first,
		 (params['show'].first || CONFIG[:commits_per_page]).to_i,
		 params['start'].first || params['branch'].first || 'master',
		 params['branch'].first || 'master']
	end

	def commitdata(ary)
		commit = { :hash => ary.shift.split.last,
		           :tree => ary.shift.split.last }
		commit[:parent] = [] if(ary.first.match(/^parent/))
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
			commit[:author_time] = Time.at(author[3].to_i)
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
			commit[:committer_time] = Time.at(committer[3].to_i)
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

		CONFIG[:groups].each_with_index { |grp, i| g = i if(grp[:name] == @group) }
		CONFIG[:groups][g][:repos].each_with_index { |repo, i| r = i if(repo[:name] == @name) }

		CONFIG[:groups][g][:repos][r] = @repoconfig

		if(File.writable?(CONFIGFILE) && YAML.load_file(CONFIGFILE) != CONFIG)
			File.open(CONFIGFILE, 'w') { |f| f.write(CONFIG.to_yaml) }
		end
	end
end
