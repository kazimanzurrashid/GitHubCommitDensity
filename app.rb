require 'sinatra'
require 'uri'
require 'net/http'
require 'json'
require 'date'

GitHubTimeline = Struct.new :id, :created_at

GitHubStat = Struct.new(:hour, :count) do
  def self.create_from(timelines)
    groups = Hash[*(0..23).map { |h| [h, 0] }.flatten]

    timelines.map { |t| t.created_at.hour }.each do |hour|
      groups[hour] += 1
    end

    groups.map do |hour, count|
      GitHubStat.new hour, count
    end.sort_by { |s| s.hour }
  end

  def label
    return '12:00 am' if hour == 0
    return '12:00 pm' if hour == 12
    return "#{hour - 12}:00 pm" if hour > 12
    "#{hour}:00 am"
  end
end

class GitHubClient
  def initialize(user, type)
    @user, @type = user, type
  end

  def timelines
    result = []

    endpoint = "https://api.github.com/users/#{@user}/events/public"
    url = URI.parse endpoint      
    http = Net::HTTP.new url.host, url.port
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    # Following is extremely evil code, will bend your server to its knees
    # or crash, use at your own risk
    (1..10).each do |page_counter|
      url.query = URI.encode_www_form({ page: page_counter })
      response = http.get url.request_uri
      unless response.is_a? Net::HTTPSuccess
        break if result.any? #return whatever we already have
        error = if body = response.body
                  json = JSON.parse body
                  json.has_key?('message') ? json['message'] : body
                else
                  "#{response.code} - #{response.message}"
                end
        raise error
      end
      json = JSON.parse response.body
      json.reject { |row| row['type'] != @type }.map do |row|
        id, created_at = row['id'], DateTime.parse(row['created_at'])
        result << GitHubTimeline.new(id, created_at)
      end
    end

    result
  end
end

get '/:user' do
  @user = params[:user] ||= ''
  halt 400, 'User name is required, try /{YOUR--USER-NAME}.' if @user.empty?

  begin
    commits = GitHubClient.new(@user, 'PushEvent').timelines
  rescue Exception => e
    halt 503, e.message 
  end

  @total = commits.count
  @stats = GitHubStat.create_from commits

  cache_control :public, max_age: 300
  erb :index, layout: false
end
