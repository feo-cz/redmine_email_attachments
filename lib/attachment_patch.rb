require 'pathname'

class AttachmentPatch
  # Maximum total size of attachments to include in email (30MB - Redmine default)
  MAX_TOTAL_ATTACHMENT_SIZE = 30.megabytes

  def self.delivering_email(message)
    Rails.logger.info "Email Attachments Plugin: Interceptor called"
    Rails.logger.info "Email Attachments Plugin: Message multipart? #{message.multipart?}"

    return unless message.multipart?

    text_part = message.text_part
    html_part = message.html_part

    Rails.logger.info "Email Attachments Plugin: text_part present? #{text_part.present?}, html_part present? #{html_part.present?}"

    # Skip if there's no HTML part or no text part (both are required for multipart/alternative)
    return unless html_part && text_part

    # IMPORTANT: Store original HTML content BEFORE any other plugins modify it
    # This ensures we can find attachments even if HTML is modified by other interceptors
    original_html_content = html_part.body.to_s
    Rails.logger.info "Email Attachments Plugin: Stored original HTML (#{original_html_content.length} chars)"

    # Define patterns dynamically to use current settings
    # Escape special regex characters in relative_url_root to prevent regex injection
    # Use safe defaults if settings are nil or empty
    protocol = Setting.protocol.presence || 'http'
    url_root = Redmine::Utils.relative_url_root.to_s
    escaped_url_root = Regexp.escape(url_root)
    base_url = "#{Regexp.escape(protocol)}://[^/]+#{escaped_url_root}"
    # Match "added" in multiple languages: added (en), přidán/a/o (cs), hinzugefügt (de), ajouté (fr), etc.
    new_file_pattern = /(<a href=")((?:#{base_url})[^"]+)"[^>]*>(.*)<\/a> (added|přidán[ao]?|hinzugefügt|ajouté|añadido|aggiunto)/i
    find_attachment_pattern = /(<a href=")((?:#{base_url})[^"]+)("[^>]*>)/

    # Look for the "File x added" text and get an array of the filenames
    # Use ORIGINAL HTML content, not current html_part.body (which may be modified by other plugins)
    new_files = []
    Rails.logger.info "Email Attachments Plugin: Looking for pattern: #{new_file_pattern.inspect}"
    Rails.logger.info "Email Attachments Plugin: HTML sample (first 500 chars): #{original_html_content[0..500]}"

    original_html_content.scan(new_file_pattern) do |match|
      Rails.logger.info "Email Attachments Plugin: Found new file match: #{match[2]}"
      new_files << match[2]
    end

    Rails.logger.info "Email Attachments Plugin: Found #{new_files.size} new files: #{new_files.inspect}"
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

    # Process ORIGINAL HTML to find attachment references
    # Use original_html_content to ensure we find all attachments even if HTML was modified
    original_html_content.scan(find_attachment_pattern) do |match|
      image_url = match[1]

      begin
        # Extract attachment ID from URL
        # Redmine 6 format: https://domain/attachments/27004 OR https://domain/attachments/download/27004/file.ext
        # Try to match numeric ID from URL
        if image_url =~ /\/attachments\/(?:download\/)?(\d+)/
          attachment_id = $1
        else
          Rails.logger.warn "Email Attachments Plugin: Could not extract attachment ID from URL: #{image_url}"
          next
        end

        # Validate that attachment_id is numeric
        next unless attachment_id =~ /\A\d+\z/

        attachment_object = Attachment.find_by(id: attachment_id)
        next unless attachment_object

        # Sanitize filename to prevent path traversal attacks
        image_name = File.basename(attachment_object.filename)

        # Skip if filename contains null bytes
        next if image_name.include?("\x00")

        # Only attach if this is a new file
        next unless new_files.include?(attachment_object.filename)

        # Use unique key combining attachment ID and filename to handle duplicate filenames
        unique_key = "#{attachment_id}_#{image_name}"

        # Skip if already in hash (prevents duplicates from same attachment added multiple times)
        next if attachment_hash.key?(unique_key)

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

        # Read file and add to hash (binary mode for images, PDFs, etc.)
        file_content = File.read(file_path, mode: 'rb')
        attachment_hash[unique_key] = { filename: image_name, content: file_content }
        total_size += file_size

        Rails.logger.info "Email Attachments Plugin: Adding attachment #{image_name} (ID: #{attachment_id}, Size: #{(file_size / 1024.0).round(2)}KB)"

      rescue Errno::ENOENT => e
        Rails.logger.error "Email Attachments Plugin: File not found for URL #{image_url}: #{e.message}"
      rescue ArgumentError => e
        Rails.logger.error "Email Attachments Plugin: Invalid URL or path for #{image_url}: #{e.message}"
      rescue SystemCallError => e
        Rails.logger.error "Email Attachments Plugin: System error reading file for URL #{image_url}: #{e.message}"
      rescue => e
        Rails.logger.error "Email Attachments Plugin: Unexpected error processing attachment from URL #{image_url}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    # Add attachments to the email
    attachment_hash.each do |unique_key, data|
      message.attachments[data[:filename]] = data[:content]
    end

    Rails.logger.info "Email Attachments Plugin: Successfully added #{attachment_hash.size} attachment(s) to email (Total: #{(total_size / 1024.0).round(2)}KB)"
  end
end

# Register interceptor normally
ActionMailer::Base.register_interceptor(AttachmentPatch)
Rails.logger.info "Email Attachments Plugin: Interceptor registered"
