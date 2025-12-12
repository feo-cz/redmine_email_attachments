require 'htmlentities'

Redmine::Plugin.register :redmine_email_attachments do
  name 'Redmine Email Attachments plugin'
  author 'Jon Goldberg'
  description 'Send attachments directly in notification emails.'
  version '0.3.0'
  url 'http://github.com/MegaphoneJon/redmine_email_attachments'
  author_url 'http://megaphonetech.com'
end

# Load the patch after Rails initialization to ensure Setting and Redmine classes are available
Rails.application.config.after_initialize do
  require_relative 'lib/attachment_patch'
end
