# frozen_string_literal: true

# Read-only extraction on Redmine 4.2 / Ruby 2.7 and Redmine 7.0, for step 7.4:
# how every text is rendered (descriptions, notes, custom and native text
# fields, wiki versions, documents and project descriptions), as a sequence
# of nodes in document order: structural tags, text, links with their full
# destination (record, operation, query and fragment) and text, and images;
# and every attachment with the SHA-256 of its file and its logical
# container.
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
require 'uri'

out = ARGV[0] || raise('usage: render_text.rb OUT.jsonl')
raise "#{out} already exists" if File.exist?(out)

FORMAT = 'render-text-v2'
# Tags that carry structure. Paragraphs, line breaks, table sections and
# spans are left out: both formatters produce them differently without
# changing what is read.
TAGS = %w[h1 h2 h3 h4 h5 h6 ul ol li table tr th td em strong del code pre blockquote hr sup sub u ins s strike].freeze
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
  own_host = Setting.host_name.to_s.sub(%r{\Ahttps?://}i, '').sub(%r{/+\z}, '').downcase
  csid_of = if legacy
              connection.select_rows('SELECT issue_id, identifier FROM cosmosys_issues').map { |id, csid| [id.to_i, csid.to_s] }.to_h
            else
              Issue.pluck(:id, :csid).map { |id, csid| [id, csid.to_s] }.to_h
            end
  item_identity = lambda do |issue|
    issue && { 'id' => issue.id, 'project' => issue.project.identifier, 'csid' => csid_of[issue.id], 'tracker' => issue.tracker.name }
  end
  sha = {}
  file_sha = lambda do |attachment|
    sha[attachment.id] ||= File.file?(attachment.diskfile) ? Digest::SHA256.file(attachment.diskfile).hexdigest : nil
  end
  principal_class = defined?(Principal) ? Principal : User
  user_identity = lambda do |id|
    principal = principal_class.find_by(id: id)
    if principal.nil? then { 'missing' => id.to_s }
    elsif defined?(AnonymousUser) && principal.is_a?(AnonymousUser) then { 'login' => '(anonymous)' }
    else { 'login' => principal.respond_to?(:login) ? principal.login.to_s : principal.to_s }
    end
  end
  # The logical container of an attachment, as both instances can name it.
  container_identity = lambda do |attachment|
    container = begin
      attachment.container
    rescue StandardError
      nil
    end
    case container
    when Issue then ['item', container.project.identifier, csid_of[container.id], container.id]
    when Document then ['document', container.project.identifier, container.title]
    when WikiPage then ['wiki', container.wiki && container.wiki.project && container.wiki.project.identifier, container.title]
    when Project then ['project', container.identifier]
    when Version then ['version', container.project.identifier, container.name]
    when nil then ['none', attachment.container_type, attachment.container_id]
    else [container.class.name, container.respond_to?(:project) && container.project ? container.project.identifier : nil, container.id]
    end
  end

  # Where a URL of the rendered HTML leads, with the part of the URL that
  # says what is done with it (operation, query and fragment).
  destination = lambda do |raw|
    url = CGI.unescapeHTML(raw.to_s)
    return { 'kind' => 'anchor' } if url.start_with?('#')
    return { 'kind' => 'mailto', 'url' => url } if url.downcase.start_with?('mailto:')

    uri = begin
      URI.parse(url)
    rescue URI::Error
      nil
    end
    return { 'kind' => 'other', 'url' => url } unless uri

    if uri.host
      host = uri.host.downcase
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ''
      local = host == 'render.invalid' || (!own_host.empty? && "#{host}#{port}#{uri.path}".start_with?(own_host))
      return { 'kind' => 'external', 'url' => url, 'host' => "#{host}#{port}" } unless local
    end
    path = uri.path.to_s
    path = path.sub(%r{\A/#{Regexp.escape(own_host.split('/', 2)[1].to_s)}(?=/)}, '') if own_host.include?('/')
    extra = { 'query' => uri.query, 'fragment' => uri.fragment }.reject { |_key, value| value.nil? }
    case path
    when %r{\A/attachments/(?:(download|thumbnail)/)?(\d+)(/.*)?\z}
      attachment = Attachment.find_by(id: Regexp.last_match(2).to_i)
      operation = Regexp.last_match(1) || 'view'
      rest = Regexp.last_match(3).to_s
      rest = rest.sub(%r{\A/[^/]*\z}, '/(name)') unless operation == 'thumbnail'
      target = attachment ? { 'id' => attachment.id, 'filename' => attachment.filename, 'sha256' => file_sha.call(attachment) } : { 'missing' => true }
      { 'kind' => 'attachment', 'attachment' => target, 'operation' => operation, 'rest' => rest }.merge(extra)
    when %r{\A/issues/(\d+)(/.*)?\z}
      issue = Issue.find_by(id: Regexp.last_match(1).to_i)
      { 'kind' => 'item', 'item' => issue ? item_identity.call(issue) : { 'missing' => true }, 'rest' => Regexp.last_match(2).to_s }.merge(extra)
    when %r{\A/(?:users|people)/(\d+)\z}
      { 'kind' => 'user', 'user' => user_identity.call(Regexp.last_match(1).to_i) }.merge(extra)
    else
      { 'kind' => 'other', 'path' => path }.merge(extra)
    end
  end
  attribute = ->(attributes, name) { attributes[/\b#{name}="([^"]*)"/i, 1] }

  # The rendered HTML as nodes: [tag], ["/" + tag], ["text", text],
  # ["link", destination, text], ["img", destination]. Text is unescaped,
  # with runs of whitespace made one space (the comparison trims it); a code
  # element inside pre is left out (Redmine 4.2 writes <pre>, Redmine 7
  # <pre><code>).
  nodes_of = lambda do |html|
    nodes = []
    link = nil
    pre = 0
    add_text = lambda do |text|
      text = text.gsub(/\s+/, ' ')
      if nodes.last && nodes.last[0] == 'text'
        nodes.last[1] += text
      else
        nodes << ['text', text]
      end
    end
    html.to_s.scan(%r{<[^>]*>|[^<]+}) do |token|
      unless token.start_with?('<')
        text = CGI.unescapeHTML(token)
        link ? link[1] << text : add_text.call(text)
        next
      end
      match = token.match(%r{\A<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>}m)
      next unless match

      closing = match[1] == '/'
      name = match[2].downcase
      case name
      when 'a'
        if closing
          nodes << ['link', link[0], link[1].gsub(/\s+/, ' ').strip] if link
          link = nil
        else
          href = attribute.call(match[3], 'href')
          link = href ? [destination.call(href), +''] : nil
        end
      when 'img'
        target = destination.call(attribute.call(match[3], 'src'))
        working = %w[attachment external].include?(target['kind']) && !(target['attachment'] && target['attachment']['missing'])
        nodes << ['img', working ? target : { 'kind' => 'broken' }]
      when 'pre'
        pre += closing ? -1 : 1
        nodes << [closing ? '/pre' : 'pre']
      else
        next unless TAGS.include?(name)
        next if name == 'code' && pre.positive?

        nodes << [closing ? "/#{name}" : name]
      end
    end
    nodes
  end

  File.open(out, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.chmod(0o600)
    file.puts JSON.generate('format' => FORMAT, 'kind' => 'meta', 'redmine' => Redmine::VERSION.to_s, 'host' => own_host,
                            'protocol' => Setting.protocol.to_s, 'text_formatting' => Setting.text_formatting.to_s)
    emit = lambda do |row, raw, html|
      file.puts JSON.generate(row.merge('format' => FORMAT, 'kind' => 'text', 'raw_sha256' => Digest::SHA256.hexdigest(raw.to_s),
                                        'markers' => raw.to_s.scan(/snapshots-gen-(?:item|user|attachment|hash)-\d+/).length,
                                        'nodes' => nodes_of.call(html)))
    end
    template = '<%= textilizable(@object, @attribute, only_path: true) %>'
    template_text = '<%= textilizable(@text, only_path: true, attachments: @attachments, project: @project, object: @object) %>'
    # A custom value as the issue page shows it (formatted or literal).
    template_value = '<%= @value.custom_field.format.formatted_custom_value(self, @value, true) %>'
    render = ->(text_template, assigns) { renderer.render(inline: text_template, assigns: assigns) }

    Issue.includes(:project).order(:id).find_each do |issue|
      unless issue.description.to_s.strip.empty?
        emit.call({ 'type' => 'description', 'id' => issue.id, 'item' => item_identity.call(issue) }, issue.description,
                  render.call(template, object: issue, attribute: :description))
      end
    end
    Journal.where(journalized_type: 'Issue').where.not(notes: [nil, '']).order(:id).find_each do |journal|
      issue = journal.journalized
      next unless issue

      emit.call({ 'type' => 'note', 'id' => journal.id, 'item' => item_identity.call(issue),
                  'at' => journal.created_on.utc.iso8601(6) }, journal.notes, render.call(template, object: journal, attribute: :notes))
    end
    # Every string, text and link value of an issue custom field, rendered
    # as the issue page renders it, and the native text fields of cosmoSys
    # Requirements.
    fields = CustomField.where(type: 'IssueCustomField', field_format: %w[string text link]).to_a
    CustomValue.where(custom_field_id: fields.map(&:id), customized_type: 'Issue').where.not(value: [nil, '']).order(:id).each do |value|
      issue = Issue.find_by(id: value.customized_id)
      next if issue.nil? || value.value.to_s.strip.empty?

      emit.call({ 'type' => 'field', 'id' => issue.id, 'item' => item_identity.call(issue), 'field' => value.custom_field.name },
                value.value, render.call(template_value, value: value))
    end
    native = %w[rq_rationale rq_srcs rq_compl_justif rq_verif_description] & Issue.column_names
    unless native.empty?
      Issue.includes(:project).order(:id).find_each do |issue|
        native.each do |name|
          text = issue.send(name)
          next if text.to_s.strip.empty?

          emit.call({ 'type' => 'field', 'id' => issue.id, 'item' => item_identity.call(issue), 'field' => name }, text,
                    render.call(template, object: issue, attribute: name.to_sym))
        end
      end
    end
    WikiPage.includes(wiki: :project).order(:id).each do |page|
      next unless page.content

      WikiContentVersion.where(wiki_content_id: page.content.id).order(:version).each do |version|
        emit.call({ 'type' => 'wiki', 'id' => version.id, 'page' => { 'project' => page.wiki.project.identifier, 'title' => page.title,
                                                                      'version' => version.version } },
                  version.text, render.call(template_text, text: version.text, attachments: page.attachments.to_a,
                                                           project: page.wiki.project, object: page))
      end
    end
    Document.includes(:project).order(:id).each do |document|
      next if document.description.to_s.strip.empty?

      emit.call({ 'type' => 'document', 'id' => document.id, 'document' => { 'project' => document.project.identifier, 'title' => document.title } },
                document.description, render.call(template, object: document, attribute: :description))
    end
    Project.order(:id).each do |project|
      next if project.description.to_s.strip.empty?

      emit.call({ 'type' => 'project', 'id' => project.id, 'project' => project.identifier }, project.description,
                render.call(template_text, text: project.description, attachments: [], project: project, object: project))
    end

    Attachment.order(:id).each do |attachment|
      container = container_identity.call(attachment)
      file.puts JSON.generate('format' => FORMAT, 'kind' => 'attachment', 'id' => attachment.id, 'filename' => attachment.filename,
                              'sha256' => file_sha.call(attachment), 'container_type' => attachment.container_type,
                              'container' => container, 'project' => container[0] == 'none' ? nil : container[1])
    end
  end
ensure
  connection.execute('ROLLBACK')
end
puts "wrote #{out}"
