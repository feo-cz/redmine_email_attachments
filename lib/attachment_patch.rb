require 'pathname'

class AttachmentPatch
  # Maximum total size of attachments to include in email (30MB - Redmine default)
  MAX_TOTAL_ATTACHMENT_SIZE = 30.megabytes

  def self.delivering_email(message)
    return unless message.multipart?

    text_part = message.text_part
    html_part = message.html_part

    # Skip if there's no HTML part or no text part (both are required for multipart/alternative)
    return unless html_part && text_part

    # Define patterns dynamically to use current settings
    # Escape special regex characters in relative_url_root to prevent regex injection
    escaped_url_root = Regexp.escape(Redmine::Utils.relative_url_root.to_s)
    base_url = "#{Regexp.escape(Setting.protocol.to_s)}://[^/]+#{escaped_url_root}"
    new_file_pattern = /(<a href=")((?:#{base_url})[^"]+)"[^>]*>(.*)<\/a> added/
    find_attachment_pattern = /(<a href=")((?:#{base_url})[^"]+)("[^>]*>)/

    # Look for the "File x added" text and get an array of the filenames
    new_files = []
    html_part.body.to_s.scan(new_file_pattern) do |match|
      new_files << match[2]
    end

    return unless new_files.any?

    # Change the MIME type from "multipart/alternative" to "multipart/mixed"
    original_mail_part = Mail::Part.new
    original_mail_part.content_type = 'multipart/alternative'
    original_mail_part.add_part text_part
    original_mail_part.add_part html_part
    message.parts.clear
    message.add_part original_mail_part
    message.content_type = message.content_type.sub(/alternative/, 'mixed')

    Rails.logger.info "Email Attachments Plugin: Converting email to multipart/mixed (content_type: #{message.content_type})"

    # Preserve original behavior: add space after body tag
    # This was in the original plugin - keeping for compatibility
    html_part.body = html_part.body.to_s.gsub(/<body[^>]*>/, "\\0 ")

    attachment_hash = {}
    total_size = 0

    # Process HTML to find attachment references
    html_content = html_part.body.to_s

    html_content.scan(find_attachment_pattern) do |match|
      image_url = match[1]

      begin
        # Extract attachment ID from URL using Pathname
        # This expects URL format like: http://domain/redmine/attachments/download/123/filename.ext
        attachment_id = Pathname.new(image_url).dirname.basename.to_s

        # Validate that attachment_id is numeric
        next unless attachment_id =~ /\A\d+\z/

        attachment_object = Attachment.find_by(id: attachment_id)
        next unless attachment_object

        # Sanitize filename to prevent path traversal attacks
        image_name = File.basename(attachment_object.filename)

        # Skip if filename contains suspicious characters
        next if image_name.include?("\x00") || image_name.include?("../")

        # Only attach if this is a new file
        next unless new_files.include?(attachment_object.filename)

        # Skip if already in hash (prevents duplicates from same attachment added multiple times)
        next if attachment_hash.key?(image_name)

        # Check file size before reading
        file_size = attachment_object.filesize || 0

        # Skip if adding this file would exceed the size limit
        if total_size + file_size > MAX_TOTAL_ATTACHMENT_SIZE
          Rails.logger.warn "Email Attachments Plugin: Skipping #{image_name} - would exceed #{MAX_TOTAL_ATTACHMENT_SIZE / 1.megabyte}MB limit"
          next
        end

        # Use Redmine's API to get the file path (works across Redmine versions)
        file_path = attachment_object.diskfile

        unless File.exist?(file_path)
          Rails.logger.warn "Email Attachments Plugin: File not found for attachment #{image_name}: #{file_path}"
          next
        end

        # Read file and add to hash
        file_content = File.read(file_path)
        attachment_hash[image_name] = file_content
        total_size += file_size

        Rails.logger.info "Email Attachments Plugin: Adding attachment #{image_name} (ID: #{attachment_id}, Size: #{file_size / 1024}KB)"

      rescue Errno::ENOENT => e
        Rails.logger.error "Email Attachments Plugin: File not found for URL #{image_url}: #{e.message}"
      rescue => e
        Rails.logger.error "Email Attachments Plugin: Error processing attachment from URL #{image_url}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    # Add attachments to the email
    attachment_hash.each do |image_name, file_content|
      message.attachments[image_name] = file_content
    end

    Rails.logger.info "Email Attachments Plugin: Successfully added #{attachment_hash.size} attachment(s) to email (Total: #{total_size / 1024}KB)"
  end
end

ActionMailer::Base.register_interceptor(AttachmentPatch)
