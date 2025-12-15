require 'htmlentities'

Redmine::Plugin.register :redmine_email_attachments do
  name 'Redmine Email Attachments plugin'
  author 'FEO'
  description 'Send attachments directly in notification emails. Upgraded for Redmine 6 compatibility. Original by Jon Goldberg.'
  version '0.3.0'
  url 'https://github.com/feo-cz/redmine_email_attachments'
  author_url 'https://www.feo.cz'
  requires_redmine version_or_higher: '6.0.0'
end

# Load the patch after Rails initialization to ensure Setting and Redmine classes are available
Rails.application.config.after_initialize do
  Rails.logger.info "Email Attachments Plugin: Loading attachment_patch.rb"
  require_relative 'lib/attachment_patch'
  Rails.logger.info "Email Attachments Plugin: attachment_patch.rb loaded, interceptor should be registered"
#  Rails.logger.info "Email Attachments Plugin: Registered interceptors: #{ActionMailer::Base.mail_interceptors.inspect}"
end
