require 'rubygems'

require 'cgi'
require 'fileutils'
require 'httparty'
require 'nokogiri'
require 'time'

###
#
# Script configuration - all options are required.

start_date = Date.civil(2010, 1, 1)   # 1) Set the export start date
end_date   = Date.civil(2010, 12, 31) # 2) Set the export end date, inclusive
api_token  = ''                       # 3) Your API token goes here 
                                      #    (see "My Info" in Campfire)
subdomain  = ''                       # 4) Your Campfire subdomain goes here
                                      #    (e.g., 'mycompany')
#
#
###

base_url = "https://#{subdomain}.campfirenow.com"

def log_error(message)
  $stderr.puts "*** Error: #{message}"
end

def get(path, params = {})
  HTTParty.get "#{base_url}#{path}",
    :query      => params,
    :basic_auth => {:username => api_token, :password => 'X'}
end

def username(id)
  @usernames     ||= {}
  @usernames[id] ||= begin
    doc = Nokogiri::XML get("/users/#{id}.xml").body
    doc.css('name').text
  end
end

def export(content, directory, filename, mode='w')
  open("#{directory}/#{filename}", mode) do |file|
    begin
      file.write content
    rescue
      log_error("export of #{directory}/#{filename} failed: #{$!}")
    end
  end
end

def export_upload(message, directory)
  # Get the upload object corresponding to this message.
  room_id = message.css('room-id').text
  message_id = message.css('id').text
  upload_path = "/room/#{room_id}/messages/#{message_id}/upload.xml"
  upload = Nokogiri::XML get(upload_path)

  # Get the upload itself and export it.
  upload_id = upload.css('id').text
  filename = upload.css('name').text
  content_path = "/room/#{room_id}/uploads/#{upload_id}/#{CGI.escape(filename)}"
  content = get(content_path)

  if content.length > 0
    export(content, directory, filename, 'wb')
  else
    log_error("download of #{directory}/#{filename} failed.")
  end
end

def indent(string, count)
  (' ' * count) + gsub(/(\n+)/) { $1 + (' ' * count) }
end

def message_to_string(message)
  user = username message.css('user-id').text
  type = message.css('type').text
  
  body = message.css('body').text
  time = Time.parse message.css('created-at').text
  timestamp = time.strftime '[%H:%M:%S]'
  
  case type
  when 'EnterMessage'
    "#{timestamp} #{user} has entered the room"
  when 'KickMessage', 'LeaveMessage'
    "#{timestamp} #{user} has left the room"
  when 'TextMessage'
    "#{timestamp} #{user}: #{body}"
  when 'UploadMessage'
    "#{timestamp} #{user} uploaded '#{body}'"
  when 'PasteMessage'
    "#{timestamp} #{user} pasted:\n#{indent(body, 4)}"
  when 'TopicChangeMessage'
    "#{timestamp} #{user} changed the topic to '#{body}'"
  when 'ConferenceCreatedMessage'
    "#{timestamp} #{user} created conference #{body}"
  when 'AllowGuestsMessage'
    "#{timestamp} #{user} opened the room to guests"
  when 'DisallowGuestsMessage'
    "#{timestamp} #{user} closed the room to guests"
  when 'IdleMessage'
    "#{timestamp} #{user} went idle"
  when 'UnidleMessage'
    "#{timestamp} #{user} became active"
  when 'TweetMessage'
    "#{timestamp} #{user} tweeted #{body}"
  when 'TimestampMessage'
    ""
  when 'AdvertisementMessage'
    ""
  else
    log_error("unknown message type: #{type} - '#{body}'")
    ""
  end
end

def zero_pad(number)
  "%02d" % number
end

def directory_for(room, date)
  "campfire/#{subdomain}/#{room}/#{date.year}/#{zero_pad(date.mon)}/#{zero_pad(date.day)}"
end

doc = Nokogiri::XML get('/rooms.xml').body
doc.css('room').each do |room_xml|
  room = room_xml.css('name').text
  id   = room_xml.css('id').text  
  date = start_date

  while date <= end_date
    export_dir = directory_for(room, date)
    print "#{export_dir} ... "
    transcript_path = "/room/#{id}/transcript/#{date.year}/#{date.mon}/#{date.mday}"
    transcript_xml = Nokogiri::XML get("#{transcript_path}.xml").body
    messages = transcript_xml.css('message')
    
    # Only export transcripts that contain at least one message.
    if messages.length > 0
      puts "exporting"
      FileUtils.mkdir_p output_directory
      transcript_html = get(transcript_path)
      plaintext = "#{room_xml.css('name').text} Transcript\n"
    
      messages.each do |message|
        if message.css('type').text == "UploadMessage"
          export_upload(message, output_directory)
        else
          message_text = message_to_string(message)
          plaintext << message_text << "\n" if message_text.length > 0
        end
      end
      
      # FIXME: These should all be command-line options.
      export(transcript_xml,  export_dir, 'transcript.xml')
      export(transcript_html, export_dir, 'transcript.html')
      export(plaintext,       export_dir, 'transcript.txt')
    else
      puts "no messages, skipping"
    end

    # Ensure that we stay well below the 37signals API limits.
    sleep(1.0/10.0)
    date = date.next
  end
end
