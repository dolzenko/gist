%w(../
   ../../lib).each { |load_path| $LOAD_PATH.unshift(File.expand_path(load_path, __FILE__)) }

require "gist"
require "net/http"
require "tmpdir"

describe Gist do
  before do
    if [ Gist.send(:config, "github.user"), Gist.send(:config, "github.token") ].any?(&:empty?)
      raise "GitHub credentials are required to run tests"
    end
  end

  after :each do
    if @gist
      Gist.delete(@gist)
    end
  end

  def with_file(name, content = nil)
    path = File.join(Dir.tmpdir, name)
    File.open(path, "w") do |f|
      f.write(content || "# test file used by gist test suite, should be removed\n\ndef qwe\nend")
    end
    yield path
  ensure
    File.delete(path)
  end

  describe "#execute" do
    it "posts gist of one file" do
      with_file("gist_test_single.rb") do |p|
        @gist = Gist.execute(p)
        @gist.should match(%r{ http://gist.github.com/\d+ }x)
        Net::HTTP.get_response(URI.parse(@gist)).should be_instance_of(Net::HTTPOK)
      end
    end

    it "posts gist of multiple files" 
#    do
#      with_file("gist_test_multiple_1.rb") do |p1|
#        with_file("gist_test_multiple_2.rb") do |p2|
#          @gist = Gist.execute(p1, p2)
#          @gist.should match(%r{ http://gist.github.com/\d+ }x)
#          Net::HTTP.get_response(URI.parse(@gist)).should be_instance_of(Net::HTTPOK)
#        end
#      end
#    end

    it "deletes gist" do
      with_file("gist_test_delete.rb") do |p|
        gist_url = Gist.execute(p)
        Net::HTTP.get_response(URI.parse(gist_url)).should be_instance_of(Net::HTTPOK)
        Gist.execute("-d", gist_url)
        open(gist_url).read.should_not include("test file used by gist test suite")
      end
    end

    it "updates gist" do
      with_file("gist_test_update.rb") do |p|
        @gist = Gist.execute(p)
        open(@gist).read.should include("test file used by gist test suite")
        File.open(p, "w") do |f|
          f.write "# test file used by gist test suite, should be removed 42"
        end
        Gist.execute("-u", p)
        open(@gist).read.should include("should be removed 42")
      end
    end
  end
end