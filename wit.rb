require 'cgi'
require 'yaml'

require 'git'

CONFIGFILE = 'config.yaml'

class Wit
	attr_accessor :path
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
		if file = ENV['PATH_TRANSLATED'] # Apache
			begin
				break if File.exists?(file)
			end while file != (file = File.split(file).first)
		else # Lighttpd
			file = ENV['SCRIPT_FILENAME']
		end

		cgi = CGI.new
		params = cgi.params
		pathinfo = (cgi.path_info || '').split(File.basename(file))
		pathinfo = (pathinfo.last || '').split('/').delete_if { |a| a.empty? } || []
		pathinfo.map! { |s| CGI.unescape(s) }

		@path = ENV['REQUEST_URI'].split(File.basename(file)).first.sub(/\/+$/, '')

		# some default values
		@config[:title] ||= 'Wit'
		@config[:commit_time_format] ||= '%Y/%m/%d %H:%M:%S'
		@config[:git_bin] ||= 'git'
		@config[:tab_width] ||= 4
		@config[:commits_per_page] ||= 50
		try_find_repos

		# some attributes
		@title = @config[:title]
		@group = pathinfo.shift || params['group'].first
		@name = pathinfo.shift || params['name'].first
		@limit = params['limit'].first || @config[:commits_per_page]
		@branch = CGI.unescape(params['branch'].first || 'master')
		@obj = params['obj'].first || '.'
		@head = CGI.unescape(params['head'].first || @branch)
		@parent = params['parent'].first
		@parent = CGI.unescape(@parent) if @parent

		attrs = ['title', 'group', 'name', 'limit', 'branch', 'obj', 'head', 'parent']
		attrs.each do |name|
			str = "
				def #{name}
					escape(@#{name}) if @#{name}
				end"
			instance_eval(str)
		end

		if(@group && @name)
			@group, @name = CGI.unescape(@group), CGI.unescape(@name)
			group = @config[:groups].find { |grp| grp[:name] == @group }
			return unless group && repos = group[:repos]
			@repoconfig = repos.find { |repo| repo[:name] == @name }
			return unless @repoconfig
			@repo = Repo.new(@config[:git_bin], @repoconfig[:path])
		end
	end

	def groups(&block)
		@config[:groups].each do |group|
			yield(escape(group[:name]))
		end
	end

	def repos(group, &block)
		@config[:groups].find { |h| h[:name] == group }[:repos].each_with_index do |repinfo, i|
			repo = Repo.new(@config[:git_bin], repinfo[:path])
			info = repinfo.values_at(:name, :description, :owner, :clone_url)
			lastcom = repo.commits.first
			time = [lastcom[:author_time], lastcom[:committer_time]].compact.max
			info.push(lastcom[:hash], lastcom[:parent].first)
			info.push(lastcom[:title], last_update(time))
			yield(i % 2 == 0 ? 'odd' : 'even', *info.map {|str| escape(str)})
		end
	end

	def commits(num = nil, &block)
		timefmt = @config[:commit_time_format]

		@repo.commits(num || @limit, @head).each_with_index do |commit, i|
			rawtime = [commit[:author_time], commit[:committer_time]].compact.max
			if @config[:elapsed_commit_times] ||= true
				time = last_update(rawtime)
			else
				time = rawtime.utc.strftime(timefmt) if(rawtime)
			end
			info = [time, commit[:author] || commit[:committer],
			        commit[:title],
			        [commit[:title], commit[:description]].join("\n"),
			        commit[:hash]]

			info.map! {|str| escape(str)}
			info[0][:plain] = rawtime
			info.insert(3, commit_substitutions(info[2][:html]))
			yield(i % 2 == 0 ? 'odd' : 'even', *info)
		end
	end

	def branches
		@repo.branches.each_with_index do |branch, i|
			yield(i % 2 == 0 ? 'odd' : 'even', escape(branch))
		end
	end

	def next_page(&block)
		commits = @repo.commits(@limit + 1, @head)
		last = commits ? commits.pop : nil

		yield(escape(last[:hash])) if(last && commits && commits.last &&
		      last[:hash] != commits.last[:hash])
	end

	def diff(&block)
		@parent ||= (@repo.commits(1, @head).first[:parent] || []).first

		@repo.diff(@head, @parent).map do |line|
			style = 'diff'

			case(line)
				when(/^@/)
					style = 'purple'
				when(/^\+/)
					style = 'green'
				when(/^-/)
					style = 'red'
			end

			line.gsub!(/\t/, ' ' * @config[:tab_width])
			yield(style, escape(line))
		end
	end

	def tree(&block)
		@repo.tree(@head, File.join(@obj, File::SEPARATOR)).each_with_index do |object, i|
			info = [object[:type], object[:mode], object[:hash], File.basename(object[:name])]
			yield(i % 2 == 0 ? 'odd' : 'even', *info.map {|str| escape(str)})
		end
	end

	def blob(&block)
		hash = @repo.tree(@head, @obj).first[:hash]

		@repo.blob(hash).each_with_index do |line, i|
			yield(i + 1, escape(line))
		end
	end

	def blame(&block)
		ary = @repo.blame(@head, @obj.sub(/^(?:\.\/|\/)+/, ''))

		ary.each_with_index do |group, i|
			hash = ary.find { |a| a[:hash] == group[:hash] }
			group = hash.merge(group) if hash
			group.each { |key, val| group[key] = escape(val) if val.is_a?(String) }
			group[:lines].each do |line|
				line.each { |key, val| line[key] = escape(val) if val.is_a?(String) }
			end
			author = group[:author] || group[:committer]
			time = group[:author_time] || group[:committer_time]
			info = [author, group[:summary], escape(last_update(time)),
			        group[:lines]]
			info[2][:plain] = time
			yield(i % 2 == 0 ? 'odd' : 'even', *info)
		end
	end

	def commit_info(&block)
		cominfo = @repo.commits(1, @head).first
		timefmt = @config[:commit_time_format]
		info = []
		tmp = nil

		tmp = cominfo[:author_email]
		tmp.sub!('@', ' at ') if @config[:protect_email_addresses] ||= false
		time = last_update(cominfo[:author_time])
		info.push(['author', "#{cominfo[:author]} <#{tmp}> (#{time})"])
		tmp = cominfo[:committer_email]
		tmp.sub!('@', ' at ') if @config[:protect_email_addresses] ||= false
		time = last_update(cominfo[:committer_time])
		info.push(['committer', "#{cominfo[:committer]} <#{tmp}> (#{time})"])
		tmp = [cominfo[:title], cominfo[:description]].join("\n")
		info.push(['commit message', commit_substitutions(CGI.escapeHTML(tmp))])
		tmp = cominfo[:author_time]
		info.push(['author time', tmp.utc.strftime(timefmt)]) if(tmp)
		tmp = cominfo[:committer_time]
		info.push(['committer time', tmp.utc.strftime(timefmt)]) if(tmp)
		info.push(['commit hash', cominfo[:hash]])

		info.each do |(key, val)|
			yield escape(key), key == 'commit message' ? val : escape(val)
		end
	end

	def commit_substitutions(commit)
		return unless @repoconfig

		(@repoconfig[:substitutions] ||= []).each do |sub|
			next unless sub[:regexp] && sub[:replace]
			regexp = Regexp.compile(sub[:regexp])
			if sub[:global]
				commit.gsub(regexp, sub[:replace].to_s)
			else
				commit.sub(regexp, sub[:replace].to_s)
			end
		end

		commit
	end

	def repo_info(&block)
		commit = @repo.commits.first
		time = [commit[:author_time], commit[:committer_time]].compact.max
		info = [['Group', @group],
		        ['Name', @name],
		        ['Description', @repoconfig[:description]],
		        ['Last updated', last_update(time)]]
		info.push(['Clone URL', @repoconfig[:clone_url]]) if @repoconfig[:clone_url]

		info.each { |(key, val)| yield(escape(key.to_s), escape(val.to_s)) }
	end

	def close
		save_config
	end

	private

	def escape(str)
		return {} unless str

		{ :plain => str,
		  :html => CGI.escapeHTML(str).gsub("\n", '<br/>'),
		  :url => CGI.escapeHTML(CGI.escape(str)) }
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

	def tree(head, tree)
		@git.ls_tree(head, tree).split("\n").map do |obj|
			# we can't just split here since the filename could have spaces
			ary = obj.match(/^(\d+)\s+(\w+)\s+(.*?)\s+(.*)$/).to_a
			ary.shift

			{ :mode => ary.shift,
			  :type => ary.shift,
			  :hash => ary.shift,
			  :name => ary.shift }
		end
	end

	def blob(obj)
		@git.cat_file('-p', obj).split("\n")
	end

	def blame(head, obj)
		data = @git.blame('-p', '--since', head, '--', obj).split("\n")
		blames = []

		data.each do |line|
			ary = line.split(/\s+/)

			case ary.first
				when /\w{40}/
					if match = line.match(/(\w{40})\s+(\d+)\s+(\d+)\s+(\d+)/)
						line = { :hash => match[1],
						         :lineno_orig => match[2].to_i,
						         :lineno_final => match[3].to_i,
						         :num_lines => match[4].to_i }
						blames.push({ :lines => [line] })
					elsif match = line.match(/(\w{40})\s+(\d+)\s+(\d+)/)
						line = { :hash => match[1],
						         :lineno_orig => match[2].to_i,
						         :lineno_final => match[3].to_i }
						blames.last[:lines].push(line)
					end
				when /author|committer/
					case ary.first
						when /(.+)-mail$/
							# I hate using $1.
							blames.last[:"#{$1}_email"] = ary.last[1..-2]
						when /(.+)-time$/
							# Really, I do.
							blames.last[:"#{$1}_time"] = Time.at(ary.last.to_i)
						when /-tz$/
							next
						when /(author|committer)/
							# $1 makes me feel dirty, but it's so convenient.
							blames.last[$1.to_sym] = line.sub(/#{$1}\s+/, '')
					end
				when /filename/
					blames.last[:filename] = ary.last
				when /summary/
					blames.last[:summary] = line.sub(/summary\s+/, '')
				when ''
					blames.last[:lines].last[:content] = line[1..-1]
			end
		end

		blames
	end

	private

	def commitdata(ary)
		commit = { :hash => ary.shift.split.last,
		           :tree => ary.shift.split.last }
		commit[:parent] = []
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
			commit[:description] = [commit[:description], ary.shift].compact.join("\n")
		end
		commit[:description].lstrip if(commit[:description])
	end
end
