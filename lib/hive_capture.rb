#!/usr/bin/env ruby

require 'pathname'
ENV['BUNDLE_GEMFILE'] ||= File.expand_path(
  '../../Gemfile',
  Pathname.new(__FILE__).realpath
)
require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'chamber'
require 'devicedb_comms'
require 'simple_stats_store/file_dump'
require 'fileutils'

Chamber.load(
  basepath: File.expand_path('../..', Pathname.new(__FILE__).realpath),
  namespaces: { environment: ENV['HIVE_ENVIRONMENT'] || 'development' }
)

class HiveCapture < Sinatra::Base
  require 'hive_capture/antie_config'
  require 'hive_capture/data_store'
  helpers AntieConfig

  APPLICATION_ID = 'hive_capture'
  @base_url = Chamber.env.base? ? Chamber.env.base : '/'

  set :root, File.expand_path('../../', Pathname.new(__FILE__).realpath)

  enable :sessions
  set :bind, '0.0.0.0'

  configure do
    mime_type :js, 'text/javascript'
    mime_type :css, 'text/css'
    mime_type :rc, 'text/plain'
    mime_type :ait, 'application/vnd.dvb.ait+xml'
  end

  before '/script/*' do
    content_type :js
  end

  before '/style/*' do
    content_type :css
  end

  get '/' do
    content_type index_mime_type
    session['whoami'] = params['whoami'] || session['whoami']
    session['url'] = request.url.split(/\?/)[0]
    erb :index
  end

  get '/poll/' do
    content_type :js
    db = DeviceDBComms::Device.new(
      Chamber.env.devicedb_url,
      Chamber.env.cert? && Chamber.env.cert,
    )

    response = db.register(mac: mac, device_model: model, device_brand: brand, device_type: device_type).to_json
    if params.has_key?('callback')
      "#{params['callback']}(#{response});"
    else
      response
    end
  end

  get '/poll/:id' do
    content_type :js
    db = DeviceDBComms::Device.new(
      Chamber.env.devicedb_url,
      Chamber.env.cert? && Chamber.env.cert,
    )

    t = Time.new
    response = db.set_application(params[:id].to_i, Chamber.env.app_name)
    delay = Time.new - t
    HiveCapture::DataStore.poll_delay(params[:id].to_i, delay)
    data_dump = SimpleStatsStore::FileDump.new(Chamber.env.stats_directory)
    data_dump.write(:delay, { timestamp: Time.now.to_s, device_id: params[:id].to_i, delay: delay} )

    if ! response['action']
      response['action'] = {
        'action_type' => 'message',
        'body' => "Last poll: %0.2f seconds" % delay
      }
    end

    if params.has_key?('callback')
      "#{params['callback']}(#{response.to_json});"
    else
      response.to_json
    end
  end

  # Layouts
  get '/style/layouts/:size.css' do
    erb :style_layouts_css
  end

  # Broadcast autolaunch
  get '/rc' do
    content_type :rc
    erb :rc,
        locals: {
          author: Chamber.env[:author] || 'E Noether',
          app_name: Chamber.env[:app_name].upcase || 'NO APPLICATION NAME',
          app_subdirectory: "#{Chamber.env[:app_subdirectory]}" || ''
        }
  end

  get '/ait/' do
    content_type :ait
    headers['Last-Modified'] = Time.now.strftime("%a, %d %b %Y %H:%M:%S GMT")
    headers['Accept-Ranges'] = 'bytes'
    erb :ait,
        locals: {
          org_id: Chamber.env[:org_id] || 0,
          app_id: Chamber.env[:app_id] || 0,
          app_widget_name: Chamber.env[:app_widget_name] || 'No Widget Name',
          app_params: Chamber.env[:app_params] || '?',
          app_name: Chamber.env[:app_name] || 'No Application Name',
          app_subdirectory: "#{Chamber.env[:app_subdirectory]}" || ''
        }
  end

  def height(size)
    size.scan(/^(\d+)p/)[0][0].to_i
  end

  def width(size)
    16 * height(size) / 9
  end

  def font_size(size)
    height(size) / 20
  end

  def left_margin(size)
    - height(size) / 2
  end

  def ip_address
    request.ip == '127.0.0.1' ? @env['HTTP_X_FORWARDED_FOR'] : request.ip
  end

  def mac
    `ping -c 1 #{ip_address}`
    mac = '00:00:00:00:00:00'
    if RUBY_PLATFORM =~ /darwin/
      mac = `arp -n #{ip_address} | awk '{ print \$4 }'`.chomp
    elsif RUBY_PLATFORM =~ /linux/
      mac = `arp -an #{ip_address} | awk '{ print \$4 }'`.chomp
    end

    # Match a valid MAC address or return the default
    /^([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}$/ =~ mac ?
      mac.split(/:/).map { |n| n.rjust(2, '0') }.join(':') :
      '00:00:00:00:00:00'
  end
end
