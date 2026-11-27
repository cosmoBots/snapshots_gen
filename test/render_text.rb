# frozen_string_literal: true

# Read-only extraction on Redmine 4.2 / Ruby 2.7 and Redmine 7.0, for step 7.4:
# how every text is rendered (descriptions, notes, text fields, wiki versions,
# documents and project descriptions), what each link and image of it points
# to, and the SHA-256 of every attachment's file.
#
#   rails runner render_text.rb OUT.jsonl
#
# Everything is read inside a read-only transaction that ends in a rollback.
# The output holds the visible text of every text: it is sensitive material,
# like the history extracts, and is written with mode 600.
require 'cgi'
require 'digest'
require 'json'
require 'set'

out = ARGV[0] || raise('usage: render_text.rb OUT.jsonl')
raise "#{out} already exists" if File.exist?(out)

FORMAT = 'render-text-v1'
TAGS = %w[h1 h2 h3 h4 h5 h6 ul ol li table thead tbody tr th td em strong del code pre a img blockquote hr sup sub u ins s strike].freeze
legacy = Redmine::VERSION::MAJOR < 5
connection = ActiveRecord::Base.connection
if legacy
  connection.execute('START TRANSACTION READ ONLY')
else
  connection.begin_db_transaction
  connection.execute('SET TRANSACTION READ ONLY')
end

begin
  User.current = User.where(admin: true, status: User::STATUS_ACTIVE).order(:id).first
  renderer = ApplicationController.renderer.new(http_host: 'render.invalid', https: false)
  own_host = Setting.host_name.to_s.sub(%r{\Ahttps?://}i, '').sub(%r{/+\z}, '')
  csid_of = if legacy
              connection.select_rows('SELECT issue_id, identifier FROM cosmosys_issues').map { |id, csid| [id.to_i, csid.to_s] }.to_h
            else
              Issue.pluck(:id, :csid).map { |id, csid| [id, csid.to_s] }.to_h
            end
  item_identity = lambda do |issue|
    issue && { 'id' => issue.id, 'project' => issue.project.identifier, 'csid' => csid_of[issue.id] }
  end
  sha = {}
  file_sha = lambda do |attachment|
    sha[attachment.id] ||= File.file?(attachment.diskfile) ? Digest::SHA256.file(attachment.diskfile).hexdigest : nil
  end
  attachment_identity = lambda do |id|
    attachment = Attachment.find_by(id: id)
    attachment ? { 'filename' => attachment.filename, 'sha256' => file_sha.call(attachment) } : { 'missing' => id.to_s }
  end
  principal_class = defined?(Principal) ? Principal : User
  user_identity = lambda do |id|
    principal = principal_class.find_by(id: id)
    if principal.nil? then { 'missing' => id.to_s }
    elsif defined?(AnonymousUser) && principal.is_a?(AnonymousUser) then { 'login' => '(anonymous)' }
    else { 'login' => principal.respond_to?(:login) ? principal.login.to_s : principal.to_s }
    end
  end

  # Where a URL of the rendered HTML leads: an attachment, an item or a user
  # of this instance, another site, or nothing that exists.
  destination = lambda do |url|
    url = CGI.unescapeHTML(url.to_s)
    absolute = url.match(%r{\Ahttps?://([^/]+)(/[^?#]*)?}i)
    path = if absolute
             host = absolute[1]
             local = host.casecmp?('render.invalid') || (!own_host.empty? && "#{host}#{absolute[2]}".downcase.start_with?(own_host.downcase))
             return { 'external' => url, 'host' => host.downcase } unless local

             url.sub(%r{\Ahttps?://#{Regexp.escape(own_host.empty? ? host : own_host)}}i, '').sub(%r{\Ahttps?://render\.invalid}i, '')
           else
             url
           end
    case path
    when %r{\A/attachments/(?:download/|thumbnail/)?(\d+)} then { 'attachment' => attachment_identity.call(Regexp.last_match(1).to_i) }
    when %r{\A/issues/(\d+)(?:[/?#]|\z)}
      issue = Issue.find_by(id: Regexp.last_match(1).to_i)
      { 'item' => issue ? item_identity.call(issue) : { 'missing' => Regexp.last_match(1) } }
    when %r{\A/(?:users|people)/(\d+)} then { 'user' => user_identity.call(Regexp.last_match(1).to_i) }
    else { 'other' => path }
    end
  end

  File.open(out, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.chmod(0o600)
    file.puts JSON.generate('format' => FORMAT, 'kind' => 'meta', 'redmine' => Redmine::VERSION.to_s, 'host' => own_host,
                            'protocol' => Setting.protocol.to_s, 'text_formatting' => Setting.text_formatting.to_s)
    emit = lambda do |row, raw, html|
      html = html.to_s
      images = []
      links = []
      html.scan(/<(img|a)\b([^>]*)>/i) do |tag, attributes|
        image = tag.casecmp?('img')
        url = attributes[/\b#{image ? 'src' : 'href'}="([^"]*)"/i, 1]
        next if url.nil? || url.start_with?('#') || url.start_with?('mailto:')

        target = destination.call(url)
        if image
          images << (target.key?('external') || (target['attachment'] && !target['attachment'].key?('missing')) ? target : { 'broken' => url })
        elsif (target.keys & %w[item user attachment external]).any?
          links << target
        end
      end
      tags = Hash.new(0)
      html.scan(%r{<([a-z0-9]+)\b[^>]*>}i) { |(name)| tags[name.downcase] += 1 if TAGS.include?(name.downcase) }
      visible = CGI.unescapeHTML(html.gsub(/<[^>]+>/, ' ')).gsub(/\s+/, ' ').strip
      file.puts JSON.generate(row.merge('format' => FORMAT, 'kind' => 'text', 'raw_sha256' => Digest::SHA256.hexdigest(raw.to_s),
                                        'markers' => raw.to_s.scan(/snapshots-gen-(?:item|user|attachment|hash)-\d+/).length,
                                        'tags' => tags.sort.to_h, 'visible' => visible, 'images' => images, 'links' => links))
    end
    template = '<%= textilizable(@object, @attribute, only_path: true) %>'
    template_text = '<%= textilizable(@text, only_path: true, attachments: @attachments, project: @project, object: @object) %>'
    render = ->(assigns, text_template = false) { renderer.render(inline: text_template ? template_text : template, assigns: assigns) }

    Issue.includes(:project).order(:id).find_each do |issue|
      unless issue.description.to_s.strip.empty?
        emit.call({ 'type' => 'description', 'id' => issue.id, 'item' => item_identity.call(issue) }, issue.description,
                  render.call(object: issue, attribute: :description))
      end
    end
    Journal.where(journalized_type: 'Issue').where.not(notes: [nil, '']).order(:id).find_each do |journal|
      issue = journal.journalized
      next unless issue

      emit.call({ 'type' => 'note', 'id' => journal.id, 'item' => item_identity.call(issue),
                  'at' => journal.created_on.utc.iso8601(6) }, journal.notes, render.call(object: journal, attribute: :notes))
    end
    # Text fields: custom fields of text format with full formatting, and the
    # native text fields of cosmoSys Requirements.
    full = CustomField.where(type: 'IssueCustomField', field_format: 'text').select { |field| field.text_formatting == 'full' }
    CustomValue.where(custom_field_id: full.map(&:id), customized_type: 'Issue').where.not(value: [nil, '']).order(:id).each do |value|
      issue = Issue.find_by(id: value.customized_id)
      next if issue.nil? || value.value.to_s.strip.empty?

      emit.call({ 'type' => 'field', 'id' => issue.id, 'item' => item_identity.call(issue), 'field' => value.custom_field.name },
                value.value, render.call({ text: value.value, attachments: issue.attachments.to_a, project: issue.project, object: issue }, true))
    end
    native = %w[rq_rationale rq_srcs rq_compl_justif rq_verif_description] & Issue.column_names
    unless native.empty?
      Issue.includes(:project).order(:id).find_each do |issue|
        native.each do |attribute|
          text = issue.send(attribute)
          next if text.to_s.strip.empty?

          emit.call({ 'type' => 'field', 'id' => issue.id, 'item' => item_identity.call(issue), 'field' => attribute }, text,
                    render.call(object: issue, attribute: attribute.to_sym))
        end
      end
    end
    WikiPage.includes(wiki: :project).order(:id).each do |page|
      next unless page.content

      WikiContentVersion.where(wiki_content_id: page.content.id).order(:version).each do |version|
        emit.call({ 'type' => 'wiki', 'id' => version.id, 'page' => { 'project' => page.wiki.project.identifier, 'title' => page.title,
                                                                      'version' => version.version } },
                  version.text, render.call({ text: version.text, attachments: page.attachments.to_a, project: page.wiki.project, object: page }, true))
      end
    end
    Document.includes(:project).order(:id).each do |document|
      next if document.description.to_s.strip.empty?

      emit.call({ 'type' => 'document', 'id' => document.id, 'document' => { 'project' => document.project.identifier, 'title' => document.title } },
                document.description, render.call(object: document, attribute: :description))
    end
    Project.order(:id).each do |project|
      next if project.description.to_s.strip.empty?

      emit.call({ 'type' => 'project', 'id' => project.id, 'project' => project.identifier }, project.description,
                render.call({ text: project.description, attachments: [], project: project, object: project }, true))
    end

    # Every attachment, with the SHA-256 of its file and where it belongs.
    Attachment.order(:id).each do |attachment|
      container = begin
        attachment.container
      rescue StandardError
        nil
      end
      project = case container
                when Project then container
                when WikiPage then container.wiki&.project
                else container.respond_to?(:project) ? container.project : nil
                end
      file.puts JSON.generate('format' => FORMAT, 'kind' => 'attachment', 'id' => attachment.id, 'filename' => attachment.filename,
                              'sha256' => file_sha.call(attachment), 'container_type' => attachment.container_type,
                              'project' => project&.identifier)
    end
  end
ensure
  connection.execute('ROLLBACK')
end
puts "wrote #{out}"
