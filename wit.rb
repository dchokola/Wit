require 'cgi'
require 'yaml'

require 'git'

CONFIGFILE = 'config.yaml'

class Wit
	def initialize
		begin
			@config = YAML.load_file(CONFIGFILE)
		rescue Errno::ENOENT
			begin
				File.open(CONFIGFILE, 'w') {}
			rescue Errno::EACCES
			end
			@config = {}
		end
		params = CGI.new.params

		# some default values
		@config[:title] ||= 'Wit'
		@config[:commit_time_format] ||= '%Y/%m/%d %H:%M:%S'
		@config[:git_bin] ||= 'git'
		@config[:tab_width] ||= 4
		@config[:commits_per_page] ||= 50
		@config[:description_length] ||= 30
		@config[:comment_length] ||= 30
		@config[:commit_length] ||= 50
		try_find_repos

		# some attributes
		@title = @config[:title]
		@group = params['group'].first
		@name = params['name'].first
		@limit = params['limit'].first || @config[:commits_per_page]
		@branch = params['branch'].first || 'master'
		@head = params['head'].first || @branch
		@parent = params['parent'].first

		attrs = ['title', 'group', 'name', 'limit', 'head', 'parent', 'branch']
		attrs.each do |name|
			eval("def #{name}\n@#{name} ? CGI.escapeHTML(@#{name}) : @#{name}\nend")
		end

		if(@group && @name)
			repos = @config[:groups].find { |grp| grp[:name] == @group }[:repos]
			@repoconfig = repos.find { |repo| repo[:name] == @name }
			@repo = Repo.new(@config[:git_bin], @repoconfig[:path])
		end
	end

	def groups(&block)
		@config[:groups].each { |group| yield(group[:name]) }
	end

	def repos(group, &block)
		@config[:groups].find { |h| h[:name] == group }[:repos].each_with_index do |repinfo, i|
			repo = Repo.new(@config[:git_bin], repinfo[:path])
			info = repinfo.values_at(:name, :description, :owner)
			lastcom = repo.commits.first
			info.push(trim(lastcom[:title], @config[:commit_length]))
			info.push(last_update(lastcom[:committer_time] || lastcom[:author_time]))
			yield(i % 2 == 0 ? 'odd' : 'even', *info)
		end
	end

	def commits(&block)
		timefmt = @config[:commit_time_format]
		title_len = @config[:commit_length]

		@repo.commits(@limit, @head).each_with_index do |commit, i|
			time = commit[:committer_time] || commit[:author_time]
			time = time.utc.strftime(timefmt) if(time)
			title = commit[:title]
			title = title[0..title_len] + '...' if(title && title.length > title_len)
			info = [time, commit[:author] || commit[:committer], title,
			        commit[:hash], (commit[:parent] || []).first]

			info.map { |c| CGI.escapeHTML(c || '') }
			yield(i % 2 == 0 ? 'odd' : 'even', *info)
		end
	end

	def branches
		@repo.branches.each_with_index do |branch, i|
			yield(i % 2 == 0 ? 'odd' : 'even', CGI.escapeHTML(branch))
		end
	end

	def next_page(&block)
		commits = @repo.commits(@limit + 1, @head)
		last = commits ? commits.pop : nil

		yield(last[:hash]) if(last && commits && last[:hash] != commits.last[:hash])
	end

	def diff(&block)
		parent = @parent || @repo.commits(1, @head).first[:parent].first

		@repo.diff(head, parent).map do |line|
			style = 'diff'

			case(line)
				when(/^@/)
					style = 'purple'
				when(/^\+/)
					style = 'green'
				when(/^-/)
					style = 'red'
			end

			line = CGI.escapeHTML(line.gsub(/\t/, ' ' * @config[:tab_width]))
			yield(style, line)
		end
	end

	def commit_info(&block)
		cominfo = @repo.commits(1, @head).first
		info = []
		tmp = nil
		time =

		tmp = cominfo[:author_email].sub('@', ' at ')
		time = last_update(cominfo[:author_time])
		info.push(['author', "#{cominfo[:author]} <#{tmp}> (#{time})"])
		tmp = cominfo[:committer_email].sub('@', ' at ')
		time = last_update(cominfo[:committer_time])
		info.push(['committer', "#{cominfo[:committer]} <#{tmp}> (#{time})"])
		tmp = "#{cominfo[:title]}\n#{cominfo[:description]}".chomp
		info.push(['commit message', tmp])

		info.each { |(key, val)| yield(CGI.escapeHTML(key), CGI.escapeHTML(val).gsub("\n", '<br/>')) }
	end

	def repo_info(&block)
		commit = @repo.commits.first
		time = commit[:author_time] || commit[:committer_time]
		info = [['Group', @group],
		        ['Name', @name],
		        ['Description', @repoconfig[:description]],
		        ['Last modified', last_update(time)]]

		info.each { |(key, val)| yield(CGI.escapeHTML(key), CGI.escapeHTML(val)) }
	end

	def close
		save_config
	end

	private

	def trim(str, len)
		str.length > len ? str[0..len] + '...' : str
	end

	def try_find_repos
		return if(@config[:groups].is_a?(Array))

		@config[:groups] = [{}]
		Dir.entries('.').each do |ent|
			next unless(File.directory?(ent) && !Git.new('git', ent).branch.match(/^fatal/))

			repo = { :name => ent,
			         :path => File.expand_path(ent),
			         :description => ent + ' automatically located by Wit' }
			@config[:groups].first[:name] ||= 'Autolocated by Wit'
			@config[:groups].first[:repos] ||=[]
			@config[:groups].first[:repos].push(repo)
		end
	end

	def last_update(time)
		difference = (Time.now - time).to_i

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

	def save_config
		g, r = nil, nil

		@config[:groups].each_with_index { |grp, i| g = i if(grp[:name] == @group) }
		@config[:groups][g][:repos].each_with_index { |repo, i| r = i if(repo[:name] == @name) } if(g)

		@config[:groups][g][:repos][r] = @repoconfig if(r)

		if(File.writable?(CONFIGFILE) && YAML.load_file(CONFIGFILE) != @config)
			File.open(CONFIGFILE, 'w') { |f| f.write(@config.to_yaml) }
		end
	end
end

class Repo
	def initialize(git_bin, path)
		@git = Git.new(git_bin, path)
	end

	def commits(num = 1, start = 'master')
		commits = []

		if(num > 0)
			ary = @git.rev_list('-n', num, '--pretty=raw', start).split("\n")
		else
			ary = @git.rev_list('--pretty=raw', start).split("\n")
		end
		ary = ary.map { |s| s.strip }.delete_if { |a| a.nil? || a.empty? }

		commits.push(commitdata(ary)) while(!ary.empty?)

		commits
	end

	def branches
		@git.branch.split("\n").map { |b| b.sub(/\*/, '').lstrip }
	end

	def diff(head, parent)
		@git.diff(parent || head, head).split("\n") || []
	end

	private

	def commitdata(ary)
		commit = { :hash => ary.shift.split.last,
		           :tree => ary.shift.split.last }
		commit[:parent] = [] if(ary.first.match(/^parent/))
		commit[:parent].push(ary.shift.split.last) while(ary.first.match(/^parent/))

		writer('author', ary, commit)
		writer('committer', ary, commit)
		description(ary, commit)

		commit
	end

	def writer(name, ary, commit)
		ret = nil

		if(ary.empty?)
			writer = nil
		else
			writer = ary.first.match(/^#{name}\s+(.+?)\s+<(.+?)>\s+(\d+)\s*(.*)$/)
			writer = ary.first.match(/^#{name}\s+()<(.+?)>\s+(\d+)\s*(.*)$/) unless(writer)
		end

		if(writer)
			ary.shift
			commit[name.to_sym], commit[(name + '_email').to_sym] = writer[1..2]
			commit[(name + '_time').to_sym] = Time.at(writer[3].to_i)
		end
	end

	def description(ary, commit)
		commit[:title] = ary.shift unless(ary.empty? || ary.first.match(/^commit/))

		while(!ary.empty? && !ary.first.match(/^commit/))
			commit[:description] = [commit[:description], ary.shift].join(' ')
		end
		commit[:description].lstrip if(commit[:description])
	end
end
