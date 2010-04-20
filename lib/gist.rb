require 'open-uri'
require 'net/http'
require 'optparse'
require 'yaml'

require 'gist/manpage' unless defined?(Gist::Manpage)
require 'gist/version' unless defined?(Gist::Version)

# You can use this class from other scripts with the greatest of
# ease.
#
#   >> Gist.read(gist_id)
#   Returns the body of gist_id as a string.
#
#   >> Gist.write(content)
#   Creates a gist from the string `content`. Returns the URL of the
#   new gist.
#
#   >> Gist.copy(string)
#   Copies string to the clipboard.
#
#   >> Gist.browse(url)
#   Opens URL in your default browser.
module Gist
  extend self

  GIST_URL   = 'http://gist.github.com/%s.txt'
  CREATE_URL = 'http://gist.github.com/gists'

  PROXY = ENV['HTTP_PROXY'] ? URI(ENV['HTTP_PROXY']) : nil
  PROXY_HOST = PROXY ? PROXY.host : nil
  PROXY_PORT = PROXY ? PROXY.port : nil

  # Parses command line arguments and does what needs to be done.
  def execute(*args)
    private_gist = defaults["private"]
    gist_filename = nil
    gist_extension = defaults["extension"]
    update_mode = false
    delete_mode = false

    opts = OptionParser.new do |opts|
      opts.banner = "Usage: gist [options] [filename or stdin] [gist_to_update_or_delete]"

      opts.on('-p', '--[no-]private', 'Make the gist private') do |priv|
        private_gist = priv
      end

      opts.on('-u', '--update', 'Update existing gist (tries to find the Gist by file name when gist_to_update_or_delete is not specified)') do |up_mode|
        update_mode = up_mode
      end

      opts.on('-d', '--delete', 'Deletes existing gist (tries to find the Gist by file name when gist_to_update_or_delete is not specified)') do |del_mode|
        delete_mode = del_mode
      end

      t_desc = 'Set syntax highlighting of the Gist by file extension'
      opts.on('-t', '--type [EXTENSION]', t_desc) do |extension|
        gist_extension = '.' + extension
      end

      opts.on('-m', '--man', 'Print manual') do
        Gist::Manpage.display("gist")
      end

      opts.on('-v', '--version', 'Print version') do
        puts Gist::Version
        exit
      end

      opts.on('-h', '--help', 'Display this screen') do
        puts opts
        exit
      end

      opts.on('-h', '--help', 'Display this screen') do
        puts opts
        exit
      end
    end

    opts.parse!(args)

    begin
      if $stdin.tty?
        # Run without stdin.

        # No args, print help.
        if args.empty?
          puts opts
          exit
        end
        unless delete_mode
          # Check if arg is a file. If so, grab the content.
          if File.exists?(file = args[0])
            input = File.read(file)
            gist_filename = file
            gist_extension = File.extname(file) if file.include?('.')
          else
            abort "Can't find #{file}"
          end
        end
      else
        if update_mode
          abort "When trying to update the Gist path to filename should be provided"
        end
        # Read from standard input.
        input = $stdin.read
      end

      if update_mode
        if args[-1] =~ /^#{ Regexp.escape CREATE_URL }/
          unless gist_existing_filename = find_gist_existing_filename(args[-1])
            puts "Can't determine existing gist filename for #{ args[-1] }, using source file name #{ gist_filename }"
            gist_existing_filename = gist_filename
          end
          gist_url = args[-1]
        else
          gist_url = find_gist_by_filename(gist_filename)
          gist_existing_filename = gist_filename
        end
        unless gist_url
          abort "Can't find gist for file #{ gist_filename }, specify path to the gist as the last option"
        end
        url = update(gist_url, gist_existing_filename, gist_filename, input)
        after_create_or_update(url, gist_filename)
        url
      elsif delete_mode
        gist_url = args[-1]
        delete(gist_url)
        puts "Deleted #{ gist_url }"
      else
        url = write(input, private_gist, gist_extension, gist_filename)
        after_create_or_update(url, gist_filename)
        url
      end
    rescue => e
      warn e
      puts opts
    end
  end

  def after_create_or_update(url, gist_filename)
    browse(url)
    puts copy(url)
    add_gists_cache(api_url(url), gist_filename)
  end

  def api_url(url)
    url.sub("http://gist.github.com/", "http://gist.github.com/gists/")
  end

  def display_url(url)
    url.sub("http://gist.github.com/gists/", "http://gist.github.com/")
  end

  def find_gist_existing_filename(gist_url)
    open(File.join(gist_url, "edit")).read[/name="file_name\[(.+?)\]"/, 1] rescue nil
  end

  def find_gist_by_filename(filename)
    gists_cache[filename] || update_gists_cache[filename]
  end

  def gists_cache
    (YAML.load_file(gists_cache_path) || {}) rescue {}
  end

  def add_gists_cache(gist_url, gist_filename)
    cache = gists_cache.merge(gist_filename => gist_url)
    File.open(gists_cache_path, "w") do |gists_cache_file|
      YAML.dump(cache, gists_cache_file)
    end
    cache
  end

  SIMULTANEOUS_CONNECTIONS = 10

  def update_gists_cache(user = config("github.user"))
    gist_urls = []

    open("http://gist.github.com/api/v1/xml/gists/#{ user }") do |gists|
      gist_urls = gists.read.scan(%r{ <repo>(\d+)</repo> }x).map { |gist_id| "#{ CREATE_URL }/#{ gist_id[0] }"}
    end

    puts "Updating gists cache for #{ gist_urls.size } gists..."
    cache = {}

    require 'thwait'
    gist_urls.each_slice(SIMULTANEOUS_CONNECTIONS) do |urls|
      threads = urls.map do |url|
        Thread.new { cache[open(url).read[%r{ href="/raw/.+?/.+?/(.+?)" }x, 1]] = url }
      end
      ThreadsWait.all_waits(*threads)
    end

    File.open(gists_cache_path, "w") do |gists_cache_file|
      YAML.dump(cache, gists_cache_file)
    end

    cache
  end

  def gists_cache_path
    File.join(ENV["HOME"], ".gist.rc")
  end

  # Create a gist on gist.github.com
  def write(content, private_gist = false, gist_extension = nil, gist_filename = nil)
    url = URI.parse(CREATE_URL)

    # Net::HTTP::Proxy returns Net::HTTP if PROXY_HOST is nil
    proxy = Net::HTTP::Proxy(PROXY_HOST, PROXY_PORT)
    req = proxy.post_form(url,
                          data(gist_filename, gist_extension, content, private_gist))

    req['Location']
  end

  # Update the gist on gist.github.com
  def update(put_url, gist_existing_filename, gist_filename, content)
    url = URI.parse(put_url)

    # Net::HTTP::Proxy returns Net::HTTP if PROXY_HOST is nil
    proxy = Net::HTTP::Proxy(PROXY_HOST, PROXY_PORT)
    proxy.post_form(url, update_data(gist_existing_filename, gist_filename, content))

    put_url
  end

  # Deletes gist
  def delete(gist_url)
    url = URI.parse(gist_delete_url(gist_url))

    proxy = Net::HTTP::Proxy(PROXY_HOST, PROXY_PORT)
    proxy.post_form(url, { "_method" => "delete" }.merge(auth))

    gist_url
  end

  def gist_delete_url(gist_url)
    "http://gist.github.com/delete/%s" % gist_url[/\d+/, 0]
  end

  # Given a gist id, returns its content.
  def read(gist_id)
    open(GIST_URL % gist_id).read
  end

  # Given a url, tries to open it in your browser.
  # TODO: Linux
  def browse(url)
    if RUBY_PLATFORM =~ /darwin/
      `open #{url}`
    elsif ENV["OS"] == 'Windows_NT' or
      RUBY_PLATFORM =~ /djgpp|(cyg|ms|bcc)win|mingw|wince/i
      `start "" "#{url}"`
    end
  end

  # Tries to copy passed content to the clipboard.
  def copy(content)
    cmd = case true
    when system("type pbcopy > /dev/null")
      :pbcopy
    when system("type xclip > /dev/null")
      :xclip
    when system("type putclip > /dev/null")
      :putclip
    end

    if cmd
      IO.popen(cmd.to_s, 'r+') { |clip| clip.print content }
    end

    content
  end

private
  # Give a file name, extension, content, and private boolean, returns
  # an appropriate payload for POSTing to gist.github.com
  def data(name, ext, content, private_gist)
    return {
      'file_ext[gistfile1]'      => ext ? ext : '.txt',
      'file_name[gistfile1]'     => name,
      'file_contents[gistfile1]' => content
    }.merge(private_gist ? { 'action_button' => 'private' } : {}).merge(auth)
  end

  def update_data(existing_name, name, content)
    { "file_name[#{ existing_name }]" => name,
      "file_contents[#{ existing_name }]" => content,
      "file_ext[#{ existing_name }]"      => ".ru",
      "_method" => "put" }.merge(auth)
  end

  # Returns a hash of the user's GitHub credentials if set.
  # http://github.com/guides/local-github-config
  def auth
    user  = config("github.user")
    token = config("github.token")

    user.empty? ? {} : { :login => user, :token => token }
  end

  # Returns default values based on settings in your gitconfig. See
  # git-config(1) for more information.
  #
  # Settings applicable to gist.rb are:
  #
  # gist.private - boolean
  # gist.extension - string
  def defaults
    priv = config("gist.private")
    extension = config("gist.extension")
    extension = nil if extension && extension.empty?

    return {
      "private"   => priv,
      "extension" => extension
    }
  end

  # Reads a config value using git-config(1), returning something
  # useful or nil.
  def config(key)
    str_to_bool `git config --global #{key}`.strip
  end

  # Parses a value that might appear in a .gitconfig file into
  # something useful in a Ruby script.
  def str_to_bool(str)
    if str.size > 0 and str[0].chr == '!'
      command = str[1, str.length]
      value = `#{command}`
    else
      value = str
    end

    case value.downcase.strip
    when "false", "0", "nil", "", "no", "off"
      nil
    when "true", "1", "yes", "on"
      true
    else
      value
    end
  end
end
