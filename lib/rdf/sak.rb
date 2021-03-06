# -*- coding: utf-8 -*-
require 'rdf/sak/version'

# basic stuff
require 'stringio'
require 'pathname'
require 'tempfile'

# rdf stuff
require 'uri'
require 'uri/urn'
require 'cgi/util'
require 'rdf'
require 'rdf/reasoner'
require 'linkeddata'

# my stuff
require 'xml-mixup'
require 'md-noko'
require 'uuid-ncname'
require 'rdf/sak/mimemagic'
require 'rdf/sak/util'

# ontologies, mine in particular
require 'rdf/sak/ci'
require 'rdf/sak/ibis'
# others not included in rdf.rb
require 'rdf/sak/pav'
require 'rdf/sak/scovo'
require 'rdf/sak/qb'

module RDF::SAK

  class Context
    include XML::Mixup
    include Util

    private

    # RDF::Reasoner.apply(:rdfs, :owl)

    G_OK = [RDF::Repository, RDF::Dataset, RDF::Graph].freeze
    C_OK = [Pathname, IO, String].freeze

    def coerce_to_path_or_io obj
      return obj if obj.is_a? IO
      return obj.expand_path if obj.is_a? Pathname
      raise "#{obj.inspect} is not stringable" unless obj.respond_to? :to_s
      Pathname(obj.to_s).expand_path
    end

    def coerce_graph graph = nil, type: nil
      # begin with empty graph
      out = RDF::Repository.new

      return out unless graph
      return graph if G_OK.any? { |c| graph.is_a? c }

      # now turn into an array
      graph = [graph] unless graph.is_a? Array

      graph.each do |g|
        raise 'Graph must be some kind of RDF::Graph or RDF data file' unless
          C_OK.any? { |c| g.is_a? c } || g.respond_to?(:to_s)

        opts = {}
        opts[:content_type] = type if type

        if g.is_a? Pathname
          opts[:filename] = g.expand_path.to_s
          g = g.open
        elsif g.is_a? File
          opts[:filename] = g.path
        end

        g = StringIO.new(g.to_s) unless g.is_a? IO
        reader = RDF::Reader.for(opts) do
          g.rewind
          sample = g.read 1000
          g.rewind
          sample
        end or raise "Could not find an RDF::Reader for #{opts[:content_type]}"

        reader = reader.new g, **opts
        reader.each_statement do |stmt|
          out << stmt
        end
      end

      out
    end

    def normalize_hash h
      return h unless h.is_a? Hash
      out = {}
      h.each do |k, v|
        out[k.to_s.to_sym] = v.is_a?(Hash) ? normalize_hash(v) :
          v.respond_to?(:to_a) ? v.to_a.map { |x| normalize_hash x } : v
      end
      out
    end

    def coerce_config config
      # config must either be a hash or a file name/pathname/io object
      unless config.respond_to? :to_h
        # when in rome
        require 'yaml'
        config = if config.is_a? IO
                   YAML.load config
                 else 
                   YAML.load_file Pathname.new(config).expand_path
                 end
      end

      config = normalize_hash config

      # config MUST have source and target dirs
      raise 'Config must have :source, :target, and :private directories' unless
        ([:source, :target, :private] - config.keys).empty?
      [:source, :target].each do |path|
        dir = config[path] = Pathname.new(config[path]).expand_path
        raise "#{dir} is not a readable directory" unless
          dir.directory? && dir.readable?
      end
      raise "Target directory #{config[:target]} is not writable" unless
        config[:target].writable?
      raise "Source and target directories are the same: #{config[:source]}" if
        config[:source] == config[:target]

      # we try to create the private directory
      config[:private] = config[:target] + config[:private]
      if config[:private].exist?
        raise "#{config[:private]} is not a readable/writable directory" unless
          [:directory?, :readable?, :writable?].all? do |m|
          config[:private].send m
        end
      else
        config[:private].mkpath
      end

      # config MAY have graph location(s) but we can test this other
      # ways, same goes for base URI
      if config[:graph]
        g = config[:graph]
        g = [g] unless g.is_a? Array
        config[:graph] = g.map { |x| Pathname.new(x).expand_path }
      end

      # deal with prefix map
      if config[:prefixes]
        config[:prefixes] = config[:prefixes].transform_values do |p|
          # we have to wrap this in case it fails
          begin
            RDF::Vocabulary.find_term(p) || RDF::URI(p)
          rescue
            RDF::URI(p)
          end
        end
      end

      # deal with duplicate map
      pfx = config[:prefixes] || {}
      if dups = config[:duplicate]
        base = URI(uri_pp config[:base])
        if dups.is_a? Hash
          config[:duplicate] = dups.map do |ruri, preds|
            preds = [preds] unless preds.is_a? Array
            preds.map! do |p|
              resolve_curie p, prefixes: pfx, scalar: true, coerce: :rdf
            end
            [RDF::URI((base + ruri.to_s).to_s), Set.new(preds)]
          end.to_h
        end
      end

      # rewrite maps
      config[:maps] = {} unless config[:maps].is_a? Hash
      %w(rewrite redirect gone).each do |type|
        config[:maps][type.to_sym] ||= ".#{type}.map"
      end

      # "document" maps, ie things that are never fragments
      config[:documents] = [] unless config[:documents].is_a? Array
      config[:documents].map! do |d|
        resolve_curie d.to_s, prefixes: pfx, scalar: true, coerce: :rdf
      end.compact
      config[:documents] << RDF::Vocab::FOAF.Document if
        config[:documents].empty?

      # fragment maps
      config[:fragment] = {} unless config[:fragment].is_a? Hash
      config[:fragment] = config[:fragment].map do |k, v|
        k = resolve_curie k.to_s, prefixes: pfx, scalar: true, coerce: :rdf
        v = v.respond_to?(:to_a) ? v.to_a : [v]
        v.map! do |x|
          x = x.to_s.split(/^\^+/).reverse
          [resolve_curie(x.first, prefixes: pfx,
            scalar: true, coerce: :rdf), !!x[1]]
        end
        [k, v]
      end.to_h

      config
    end

    def cmp_label a, b, labels: nil, supplant: true, reverse: false
      labels ||= {}

      # try supplied label or fall back
      pair = [a, b].map do |x|
        if labels[x]
          labels[x][1]
        elsif supplant and y = label_for(x)
          labels[x] = y
          y[1]
        else
          x
        end
      end

      pair.reverse! if reverse
      # warn "#{pair[0]} <=> #{pair[1]}"
      pair[0].to_s <=> pair[1].to_s
    end

    def term_list terms
      return [] if terms.nil?
      terms = terms.respond_to?(:to_a) ? terms.to_a : [terms]
      terms.uniq.map { |t| RDF::Vocabulary.find_term t }.compact
    end

    def coerce_resource arg
      super arg, @base
    end

    def coerce_uuid_urn arg
      super arg, @base
    end

    public

    attr_reader :config, :graph, :base

    # Initialize a context.
    #
    # @param graph
    # @param base
    # @param config
    # @param type
    #
    # @return [RDF::SAK::Context] the new context object.

    def initialize graph: nil, base: nil, config: nil, type: nil
      # RDF::Reasoner.apply(:rdfs, :owl)

      @config = coerce_config config

      graph ||= @config[:graph] if @config[:graph]
      base  ||= @config[:base]  if @config[:base]
      
      @graph  = coerce_graph graph, type: type
      @base   = RDF::URI.new base.to_s if base
      @ucache = RDF::Util::Cache.new(-1)
      @scache = {} # wtf rdf util cache doesn't like booleans
    end

    # Get the prefix mappings from the configuration.
    #
    # @return [Hash]

    def prefixes
      @config[:prefixes] || {}
    end

    # Abbreviate a set of terms against the registered namespace
    # prefixes and optional default vocabulary, or otherwise return a
    # string representation of the original URI.
    
    # @param term [RDF::Term]
    # @param prefixes [Hash]
    #
    # @return [String]
    #
    def abbreviate term, prefixes: @config[:prefixes],
        vocab: nil, noop: true, sort: true
      super term, prefixes: prefixes || {}, vocab: vocab, noop: noop, sort: sort
    end

    # Obtain a key-value structure for the given subject, optionally
    # constraining the result by node type (:resource, :uri/:iri,
    # :blank/:bnode, :literal)
    #
    # @param subject of the inquiry
    # @param rev map in reverse
    # @param only one or more node types
    # @param uuids coerce resources to if possible
    #
    # @return [Hash]
    #
    def struct_for subject, rev: false, only: [], inverses: false,
        uuids: false, canon: false, ucache: {}, scache: {}
      Util.struct_for @graph, subject,
        rev: rev, only: only, inverses: inverses, uuids: uuids, canon: canon,
        ucache: ucache, scache: scache
    end

    # Obtain everything in the graph that is an `rdf:type` of something.
    # 
    # @return [Array]
    #
    def all_types
      @graph.query([nil, RDF.type, nil]).objects.uniq
    end

    # Obtain every subject that is rdf:type the given type or its subtypes.
    #
    # @param rdftype [RDF::Term, #to_a]
    #
    # @return [Array]
    #
    def all_of_type rdftype, exclude: []
      rdftype = rdftype.respond_to?(:to_a) ? rdftype.to_a : [rdftype]
      exclude = term_list exclude

      t = rdftype.map do |t|
        RDF::Vocabulary.find_term(t) rescue nil
      end.compact.map { |t| all_related(t) }.flatten.uniq

      raise "Could not find types in #{rdftype}" if t.empty?

      out = []
      (all_types & t - exclude).each do |type|
        out += subjects_for(RDF.type, type)
      end
      
      out.uniq
    end

    # Obtain all and only the rdf:types directly asserted on the subject.
    # 
    # @param subject [RDF::Resource]
    # @param type [RDF::Term, :to_a]
    #
    # @return [Array]
    #
    def asserted_types subject, type = nil, struct: nil
      Util.asserted_types @graph, subject, type, struct: struct
    end

    # Determine whether a subject is a given `rdf:type`.
    #
    # @param repo [RDF::Queryable] the repository
    # @param subject [RDF::Resource] the resource to test
    # @param type [RDF::Term] the type to test the subject against
    # @param struct [Hash] an optional predicate-object set
    # @return [true, false]
    #
    def rdf_type? subject, type, struct: nil
      Util.rdf_type? @graph, subject, type, struct: struct
    end

    # Obtain the canonical UUID for the given URI
    #
    # @param uri [RDF::URI, URI, to_s] the subject of the inquiry
    # @param unique [true, false] return a single resource/nil or an array
    # @param published [true, false] whether to restrict to published docs
    # 
    # @return [RDF::URI, Array]
    #
    def canonical_uuid uri, unique: true, published: false
      Util.canonical_uuid @graph, uri, unique: unique,
        published: published, scache: @scache, ucache: @ucache, base: @base
    end

    # Obtain the "best" dereferenceable URI for the subject.
    # Optionally returns all candidates.
    # 
    # @param subject  [RDF::Resource]
    # @param unique   [true, false] flag for unique return value
    # @param rdf      [true, false] flag to specify RDF::URI vs URI 
    # @param slugs    [true, false] flag to include slugs
    # @param fragment [true, false] flag to include fragment URIs
    #
    # @return [RDF::URI, URI, Array]
    #
    def canonical_uri subject,
        unique: true, rdf: true, slugs: false, fragment: true
      Util.canonical_uri @graph, subject, base: @base,
        unique: unique, rdf: rdf, slugs: slugs, fragment: fragment,
        frag_map: @config[:fragment] || {}, documents: @config[:documents]
    end

    # Returns subjects from the graph with entailment.
    #
    # @param predicate
    # @param object
    # @param entail
    # @param only
    #
    # @return [RDF::Resource]
    #
    def subjects_for predicate, object, entail: true, only: [], &block
      Util.subjects_for @graph,
        predicate, object, entail: entail, only: only, &block
    end
    
    # Returns objects from the graph with entailment.
    #
    # @param subject
    # @param predicate
    # @param entail
    # @param only
    # @param datatype
    #
    # @return [RDF::Term]
    #
    def objects_for subject, predicate,
        entail: true, only: [], datatype: nil, &block
      Util.objects_for @graph, subject, predicate,
        entail: entail, only: only, datatype: datatype, &block
    end

    # Find the terminal replacements for the given subject, if any exist.
    #
    # @param subject
    # @param published indicate the context is published
    #
    # @return [Set]
    #
    def replacements_for subject, published: true
      Util.replacements_for @graph, subject, published: published
    end

    # Obtain dates for the subject as instances of Date(Time). This is
    # just shorthand for a common application of `objects_for`.
    #
    # @param subject
    # @param predicate
    # @param datatype
    #
    # @return [Array] of dates
    def dates_for subject, predicate: RDF::Vocab::DC.date,
        datatype: [RDF::XSD.date, RDF::XSD.dateTime]
      Util.dates_for @graph, subject, predicate: predicate, datatype: datatype
    end

    # Obtain any specified MIME types for the subject. Just shorthand
    # for a common application of `objects_for`.
    #
    # @param subject
    # @param predicate
    # @param datatype
    #
    # @return [Array] of internet media types
    #
    def formats_for subject, predicate: RDF::Vocab::DC.format,
        datatype: [RDF::XSD.token]
      Util.objects_for @graph, subject, predicate, datatype: datatype
    end

    # Assuming the subject is a thing that has authors, return the
    # list of authors. Try bibo:authorList first for an explicit
    # ordering, then continue to the various other predicates.
    #
    # @param subject [RDF::Resource]
    # @param unique  [false, true] only return the first author
    # @param contrib [false, true] return contributors instead of authors
    #
    # @return [RDF::Value, Array]
    #
    def authors_for subject, unique: false, contrib: false
      Util.authors_for @graph, subject, unique: unique, contrib: contrib
    end

    # Obtain the most appropriate label(s) for the subject's type(s).
    # Returns one or more (depending on the `unique` flag)
    # predicate-object pairs in order of preference.
    #
    # @param subject [RDF::Resource]
    # @param unique [true, false] only return the first pair
    # @param type [RDF::Term, Array] supply asserted types if already retrieved
    # @param lang [nil] not currently implemented (will be conneg)
    # @param desc [false, true] retrieve description instead of label
    # @param alt  [false, true] retrieve alternate instead of main
    #
    # @return [Array] either a predicate-object pair or an array of pairs.
    #
    def label_for subject, candidates: nil, unique: true, type: nil,
        lang: nil, desc: false, alt: false
      Util.label_for @graph, subject, candidates: candidates,
        unique: unique, type: type, lang: lang, desc: desc, alt: alt
    end

    SKOS_HIER = [
      {
        element: :subject,
        pattern: -> c, p { [nil, p, c] },
        preds: [RDF::Vocab::SKOS.broader,  RDF::Vocab::SKOS.broaderTransitive],
      },
      {
        element: :object,
        pattern: -> c, p { [c, p, nil] },
        preds: [RDF::Vocab::SKOS.narrower, RDF::Vocab::SKOS.narrowerTransitive],
      }
    ]
    SKOS_HIER.each do |struct|
      # lol how many times are we gonna cart this thing around
      preds = struct[:preds]
      i = 0
      loop do
        equiv = preds[i].entail(:equivalentProperty) - preds
        preds.insert(i + 1, *equiv) unless equiv.empty?
        i += equiv.length + 1;
        break if i >= preds.length
      end
    end

    def sub_concepts concept, extra: []
      raise 'Concept must be exactly one concept' unless
        concept.is_a? RDF::Resource
      extra = term_list extra

      # we need an array for a queue, and a set to accumulate the
      # output as well as a separate 'seen' set
      queue = [concept]
      seen  = Set.new queue.dup
      out   = seen.dup

      # it turns out that the main SKOS hierarchy terms, while not
      # being transitive themselves, are subproperties of transitive
      # relations which means they are as good as being transitive.

      while c = queue.shift
        SKOS_HIER.each do |struct|
          elem, pat, preds = struct.values_at(:element, :pattern, :preds)
          preds.each do |p|
            @graph.query(pat.call c, p).each do |stmt|
              # obtain hierarchical element
              hierc = stmt.send elem

              # skip any further processing if we have seen this concept
              next if seen.include? hierc
              seen << hierc

              next if !extra.empty? and !extra.any? do |t|
                @graph.has_statement? RDF::Statement.new(hierc, RDF.type, t)
              end

              queue << hierc
              out   << hierc
            end
          end
        end
      end

      out.to_a.sort
    end

    def audiences_for uuid, proximate: false, invert: false
      p = invert ? CI['non-audience'] : RDF::Vocab::DC.audience
      return @graph.query([uuid, p, nil]).objects if proximate

      out = []
      @graph.query([uuid, p, nil]).objects.each do |o|
        out += sub_concepts o
      end

      out.uniq
    end

    # Get all "reachable" UUID-identified entities (subjects which are
    # also objects)
    def reachable published: false
      p = published ? -> x { published?(x) } : -> x { true }
      # now get the subjects which are also objects
      @graph.subjects.select do |s|
        s.uri? && s =~ /^urn:uuid:/ && @graph.has_object?(s) && p.call(s)
      end
    end

    # holy cow this is actually a lot of stuff:

    # turn markdown into xhtml (via md-noko)

    # turn html into xhtml (trivial)

    # generate triples from ordinary (x)html structure

    # map vanilla (x)html metadata to existing graph (ie to get resource URIs)

    # pull triples from rdfa

    # stuff rdfa into rdfa-less xhtml

    # basic nlp detection of terms + text-level markup (dfn, abbr...)

    # markdown round-tripping (may as well store source in md if possible)

    # add title attribute to all links

    # add alt attribute to all images

    # segmentation of composite documents into multiple files

    # aggregation of simple documents into composites

    # generate backlinks

    # - resource (ie file) generation -

    # generate indexes of people, groups, and organizations

    # generate indexes of books, not-books, and other external links

    def head_links subject, struct: nil, nodes: nil, prefixes: {},
        ignore: [], uris: {}, labels: {}, vocab: nil, rev: []

      raise 'ignore must be Array or Set' unless
        [Array, Set].any? { |c| ignore.is_a? c }

      rev = rev.respond_to?(:to_a) ? rev.to_a : [rev]

      struct ||= struct_for subject
      nodes  ||= invert_struct struct

      # XXX is this smart?
      revs = {}
      subjects_for(rev, subject, only: :resource) do |s, ps|
          revs[s] ||= Set.new
          revs[s] |= ps
      end

      # make sure these are actually URI objects not RDF::URI
      uris = uris.transform_values { |v| URI(uri_pp v.to_s) }
      uri  = uris[subject] || canonical_uri(subject, rdf: false)

      ignore = ignore.to_set

      # output
      links = []

      { false => nodes, true => revs }.each do |reversed, obj|
        obj.reject { |n, _| ignore.include?(n) || !n.uri? }.each do |k, v|
          # first nuke rdf:type, that's never in there
          v = v.dup.delete RDF::RDFV.type if reversed
          next if v.empty?

          unless uris[k]
            cu = canonical_uri k
            uris[k] = cu || uri_pp(k.to_s)
          end

          # munge the url and make the tag
          ru  = uri.route_to(uris[k])
          ln  = { nil => :link, href: ru.to_s }
          ln[reversed ? :rev : :rel] = abbreviate v.to_a, vocab: vocab

          # add the title
          if lab = labels[k]
            ln[:title] = lab[1].to_s
          end

          # add type attribute
          unless (mts = formats_for k).empty?
            ln[:type] = mts.first.to_s

            if ln[:type] =~ /(java|ecma)script/i ||
                !(v.to_set & Set[RDF::Vocab::DC.requires]).empty?
              ln[:src] = ln.delete :href
              # make sure we pass in an empty string so there is a closing tag
              ln.delete nil
              ln[['']] = :script
            end
          end

          # finally add the link
          links << ln
        end
      end

      links.sort! do |a, b|
        # sort by rel, then by href
        # warn a.inspect, b.inspect
        s = 0
        [nil, :rel, :rev, :href, :title].each do |k|
          s = a.fetch(k, '').to_s <=> b.fetch(k, '').to_s
          break if s != 0
        end
        s
      end

      links
    end

    def head_meta subject, struct: nil, nodes: nil, prefixes: {},
        ignore: [], meta_names: {}, vocab: nil, lang: nil, xhtml: true

      raise 'ignore must be Array or Set' unless
        [Array, Set].any? { |c| ignore.is_a? c }

      struct ||= struct_for subject
      nodes  ||= invert_struct struct

      ignore = ignore.to_set

      meta = []
      nodes.select { |n| n.literal? && !ignore.include?(n) }.each do |k, v|
        rel  = abbreviate v.to_a, vocab: vocab
        tag  = { nil => :meta, property: rel, content: k.to_s }

        lang = (k.language? && k.language != lang ? k.language : nil) ||
          (k.datatype == RDF::XSD.string && lang ? '' : nil)
        if lang
          tag['xml:lang'] = lang if xhtml
          tag[:lang] = lang
        end

        tag[:datatype] = abbreviate k.datatype, vocab: XHV if k.datatype?
        tag[:name] = meta_names[k] if meta_names[k]

        meta << tag
      end

      meta.sort! do |a, b|
        s = 0
        [:about, :property, :datatype, :content, :name].each do |k|
          # warn a.inspect, b.inspect
          s = a.fetch(k, '').to_s <=> b.fetch(k, '').to_s
          break if s != 0
        end
        s
      end

      meta
    end

    def generate_backlinks subject, published: true, ignore: nil
      uri    = canonical_uri(subject, rdf: false) || URI(uri_pp subject)
      ignore ||= Set.new
      raise 'ignore must be amenable to a set' unless ignore.respond_to? :to_set
      ignore = ignore.to_set
      nodes  = {}
      labels = {}
      types  = {}
      @graph.query([nil, nil, subject]).each do |stmt|
        next if ignore.include?(sj = stmt.subject)
        preds = nodes[sj] ||= Set.new
        preds << (pr = stmt.predicate)
        types[sj]  ||= asserted_types sj
        labels[sj] ||= label_for sj
        labels[pr] ||= label_for pr
      end

      # prune out 
      nodes.select! { |k, _| published? k } if published
      
      return if nodes.empty?

      li = nodes.sort do |a, b|
        cmp_label a[0], b[0], labels: labels
      end.map do |rsrc, preds|
        cu  = canonical_uri(rsrc, rdf: false) or next
        lab = labels[rsrc] || [nil, rsrc]
        lp  = abbreviate(lab[0]) if lab[0]
        ty  = abbreviate(types[rsrc]) if types[rsrc]
        
        { [{ [{ [lab[1].to_s] => :span, property: lp }] => :a,
          href: uri.route_to(cu), typeof: ty, rev: abbreviate(preds) }] => :li }
      end.compact

      { [{ li => :ul }] => :nav }
    end

    def generate_twitter_meta subject
      # get author
      author = authors_for(subject, unique: true) or return []

      # get author's twitter account
      twitter = objects_for(author, RDF::Vocab::FOAF.account,
        only: :resource).select { |t| t.to_s =~ /twitter\.com/
      }.sort.first or return []
      twitter = URI(twitter.to_s).path.split(/\/+/)[1]
      twitter = ?@ + twitter unless twitter.start_with? ?@

      # get title
      title = label_for(subject) or return []

      out = [
        { nil => :meta, name: 'twitter:card', content: :summary },
        { nil => :meta, name: 'twitter:site', content: twitter },
        { nil => :meta, name: 'twitter:title', content: title[1].to_s }
      ]

      # get abstract
      if desc = label_for(subject, desc: true)
        out.push({ nil => :meta, name: 'twitter:description',
          content: desc[1].to_s })
      end

      # get image (foaf:depiction)
      img = objects_for(subject, RDF::Vocab::FOAF.depiction, only: :resource)
      unless img.empty?
        img = canonical_uri img.first
        out.push({ nil => :meta, name: 'twitter:image', content: img })
        out.first[:content] = :summary_large_image
      end

      # return the appropriate xml-mixup structure
      out
    end

    AUTHOR_SPEC = [
      ['By:', [RDF::Vocab::BIBO.authorList, RDF::Vocab::DC.creator]],
      ['With:', [RDF::Vocab::BIBO.contributorList, RDF::Vocab::DC.contributor]],
      ['Edited by:', [RDF::Vocab::BIBO.editorList, RDF::Vocab::BIBO.editor]],
      ['Translated by:', [RDF::Vocab::BIBO.translator]],
    ].freeze

    def generate_bibliography id, published: true
      id  = canonical_uuid id
      uri = canonical_uri id
      struct = struct_for id
      nodes     = Set[id] + smush_struct(struct)
      bodynodes = Set.new
      parts     = {}
      referents = {}
      labels    = { id => label_for(id, candidates: struct) }
      canon     = {}

      # uggh put these somewhere
      preds = {
        hp:    predicate_set(RDF::Vocab::DC.hasPart),
        sa:    predicate_set(RDF::RDFS.seeAlso),
        canon: predicate_set([RDF::OWL.sameAs, CI.canonical]),
        ref:   predicate_set(RDF::Vocab::DC.references),
        al:    predicate_set(RDF::Vocab::BIBO.contributorList),
        cont:  predicate_set(RDF::Vocab::DC.contributor),
      }

      # collect up all the parts (as in dct:hasPart)
      objects_for(id, preds[:hp], entail: false, only: :resource).each do |part|
        bodynodes << part

        # gather up all the possible alias urls this thing can have
        sa = ([part] + objects_for(part,
          preds[:sa], only: :uri, entail: false)).map do |x|
          [x] + subjects_for(preds[:canon], x, only: :uri, entail: false)
        end.flatten.uniq

        # collect all the referents
        reftmp = {}
        sa.each do |u|
          subjects_for preds[:ref], u, only: :uri, entail: false do |s, *p|
            reftmp[s] ||= Set.new
            reftmp[s] += p.first.to_set
          end
        end

        # if we are producing a list of references identified by only
        # published resources, prune out all the unpublished referents
        reftmp.select! { |x, _| published? x } if published

        # unconditionally skip this item if nothing references it
        next if reftmp.empty?

        referents[part] = reftmp

        reftmp.each do |r, _|
          labels[r] ||= label_for r
          canon[r]  ||= canonical_uri r
        end

        # collect all the authors and author lists

        objects_for(part, preds[:al], only: :resource, entail: false) do |o|
          RDF::List.new(subject: o, graph: @graph).each do |a|
            labels[a] ||= label_for a
          end
        end

        objects_for(part, preds[:cont], only: :uri, entail: false) do |a|
          labels[a] ||= label_for a
        end

        ps = struct_for part
        labels[part] = label_for part, candidates: ps
        nodes |= smush_struct ps

        parts[part] = ps
      end

      bmap = prepare_collation struct
      pf = -> x { abbreviate bmap[x.literal? ? :literals : :resources][x] }

      body = []
      parts.sort { |a, b| cmp_label a[0], b[0], labels: labels }.each do |k, v|
        mapping = prepare_collation v
        p = -> x {
          abbreviate mapping[x.literal? ? :literals : :resources][x] }
        t = abbreviate mapping[:types]

        lp = label_for k, candidates: v
        h2c = [lp[1].to_s]
        h2  = { h2c => :h2 }
        cu  = canonical_uri k
        rel = nil
        unless cu.scheme.downcase.start_with? 'http'
          if sa = v[RDF::RDFS.seeAlso]
            rel = p.call sa[0]
            cu = canonical_uri sa[0]
          else
            cu = nil
          end
        end

        if cu
          h2c[0] = { [lp[1].to_s] => :a, rel: rel,
            property: p.call(lp[1]), href: cu.to_s }
        else
          h2[:property] = p.call(lp[1])  
        end

        # authors &c
        # authors contributors editors translators
        al = []
        AUTHOR_SPEC.each do |label, pl|
          dd = []
          seen = Set.new
          pl.each do |pred|
            # first check if the struct has the predicate
            next unless v[pred]
            li = []
            ul = { li => :ul, rel: abbreviate(pred) }
            v[pred].sort { |a, b| cmp_label a, b, labels: labels }.each do |o|
              # check if this is a list
              tl = RDF::List.new subject: o, graph: @graph
              if tl.empty? and !seen.include? o
                seen << o
                lab = labels[o] ? { [labels[o][1]] => :span,
                  property: abbreviate(labels[o][0]) } : o
                li << { [lab] => :li, resource: o }
              else
                # XXX this will actually not be right if there are
                # multiple lists but FINE FOR NOW
                ul[:inlist] ||= ''
                tl.each do |a|
                  seen << a 
                  lab = labels[a] ? { [labels[a][1]] => :span,
                    property: abbreviate(labels[a][0]) } : a
                  li << { [lab] => :li, resource: a }
                end
              end
            end
            dd << ul unless li.empty?
          end
          al += [{ [label] => :dt }, { dd => :dd }] unless dd.empty?
        end

        # ref list
        rl = referents[k].sort do |a, b|
          cmp_label a[0], b[0], labels: labels
        end.map do |ref, pset|
          lab = labels[ref] ? { [labels[ref][1]] => :span,
            property: abbreviate(labels[ref][0]) } : ref
                  
          { [{ [lab] => :a, rev: abbreviate(pset), href: canon[ref] }] => :li }
        end

        contents = [h2, {
          al + [{ ['Referenced in:'] => :dt },
            { [{ rl => :ul }] => :dd }] => :dl }]

        body << { contents => :section,
          rel: pf.call(k), resource: k.to_s, typeof: t }
      end

      # prepend abstract to body if it exists
      abs = label_for id, candidates: struct, desc: true
      if abs
        tag = { '#p' => abs[1], property: abbreviate(abs[0]) }
        body.unshift tag
      end

      # add labels to nodes
      nodes += smush_struct labels

      # get prefixes
      pfx = prefix_subset prefixes, nodes

      # get title tag
      title = title_tag labels[id][0], labels[id][1],
        prefixes: prefixes, lang: 'en'

      # get links
      link = head_links id, struct: struct, ignore: bodynodes,
        labels: labels, vocab: XHV, rev: RDF::SAK::CI.document

      # get metas
      mn = {}
      mn[abs[1]] = :description if abs
      mi = Set.new
      mi << labels[id][1] if labels[id]
      meta = head_meta id,
        struct: struct, lang: 'en', ignore: mi, meta_names: mn, vocab: XHV

      meta += generate_twitter_meta(id) || []

      xhtml_stub(base: uri, prefix: pfx, lang: 'en', title: title, vocab: XHV,
        link: link, meta: meta, transform: @config[:transform],
        body: { body => :body, about: '',
          typeof: abbreviate(struct[RDF::RDFV.type] || []) }).document
    end

    # generate skos concept schemes

    CONCEPTS = Util.all_related(RDF::Vocab::SKOS.Concept).to_set

    def generate_audience_csv file = nil, published: true
      require 'csv'
      file = coerce_to_path_or_io file if file
      lab = {}

      out = all_internal_docs(published: published,
                              exclude: RDF::Vocab::FOAF.Image).map do |s|
        u = canonical_uri s
        x = struct_for s
        c = x[RDF::Vocab::DC.created] ? x[RDF::Vocab::DC.created][0] : nil
        _, t = label_for s, candidates: x
        _, d = label_for s, candidates: x, desc: true

        # # audience(s)
        # a = objects_for(s, RDF::Vocab::DC.audience).map do |au|
        #   next lab[au] if lab[au]
        #   _, al = label_for au
        #   lab[au] = al
        # end.map(&:to_s).sort.join '; '

        # # explicit non-audience(s)
        # n = objects_for(s, RDF::SAK::CI['non-audience']).map do |au|
        #   next lab[au] if lab[au]
        #   _, al = label_for au
        #   lab[au] = al
        # end.map(&:to_s).sort.join '; '

        # audience and non-audience
        a, n = [RDF::Vocab::DC.audience, CI['non-audience']].map do |ap|
          objects_for(s, ap).map do |au|
            next lab[au] if lab[au]
            _, al = label_for au
            lab[au] = al
          end.map(&:to_s).sort.join '; '
        end

        # concepts???
        concepts = [RDF::Vocab::DC.subject, CI.introduces,
                    CI.assumes, CI.mentions].map do |pred|
          objects_for(s, pred, only: :resource).map do |o|
            con = self.objects_for(o, RDF.type).to_set & CONCEPTS
            next if con.empty?
            next lab[o] if lab[o]
            _, ol = label_for o
            lab[o] = ol
          end.compact.map(&:to_s).sort.join '; '
        end

        [s, u, c, t, d, a, n].map(&:to_s) + concepts
      end.sort { |a, b| a[2] <=> b[2] }

      out.unshift ['ID', 'URL', 'Created', 'Title', 'Description', 'Audience',
        'Non-Audience', 'Subject', 'Introduces', 'Assumes', 'Mentions']

      if file
        # don't open until now
        file = file.expand_path.open('wb') unless file.is_a? IO

        csv = CSV.new file
        out.each { |x| csv << x }
        file.flush
      end

      out
    end

    CSV_PRED = {
      audience:    RDF::Vocab::DC.audience,
      nonaudience: CI['non-audience'],
      subject:     RDF::Vocab::DC.subject,
      assumes:     CI.assumes,
      introduces:  CI.introduces,
      mentions:    CI.mentions,
    }

    def ingest_csv file
      file = coerce_to_path_or_io file

      require 'csv'

      # key mapper
      km = { uuid: :id, url: :uri }
      kt = -> (k) { km[k] || k }

      # grab all the concepts and audiences

      audiences = {}
      all_of_type(CI.Audience).map do |c|
        s = struct_for c

        # homogenize the labels
        lab = [false, true].map do |b|
          label_for(c, candidates: s, unique: false, alt: b).map { |x| x[1] }
        end.flatten.map { |x| x.to_s.strip.downcase }

        # we want all the keys to share the same set
        set = nil
        lab.each { |t| set = audiences[t] ||= set || Set.new }
        set << c
      end

      concepts = {}
      all_of_type(RDF::Vocab::SKOS.Concept).map do |c|
        s = struct_for c

        # homogenize the labels
        lab = [false, true].map do |b|
          label_for(c, candidates: s, unique: false, alt: b).map { |x| x[1] }
        end.flatten.map { |x| x.to_s.strip.downcase }

        # we want all the keys to share the same set
        set = nil
        lab.each { |t| set = concepts[t] ||= set || Set.new }
        set << c
      end

      data = CSV.read(file, headers: true,
                      header_converters: :symbol).map do |o|
        o = o.to_h.transform_keys(&kt)
        s = canonical_uuid(o.delete :id) or next

        # LOLOL wtf

        # handle audience
        [:audience, :nonaudience].each do |a|
          if o[a]
            o[a] = o[a].strip.split(/\s*[;,]+\s*/, -1).map do |t|
              if t =~ /^[a-z+-]+:[^[:space:]]+$/
                u = RDF::URI(t)
                canonical_uuid(u) || u
              elsif audiences[t.downcase]
                audiences[t.downcase].to_a
              end
            end.flatten.compact.uniq
          else
            o[a] = []
          end
        end

        # handle concepts
        [:subject, :introduces, :assumes, :mentions].each do |a|
          if o[a]
            o[a] = o[a].strip.split(/\s*[;,]+\s*/, -1).map do |t|
              if t =~ /^[a-z+-]+:[^[:space:]]+$/
                u = RDF::URI(t)
                canonical_uuid(u) || u
              elsif concepts[t.downcase]
                concepts[t.downcase].to_a
              end
            end.flatten.compact.uniq
          else
            o[a] = []
          end

        end

        CSV_PRED.each do |sym, pred|
          o[sym].each do |obj|
            @graph << [s, pred, obj]
          end
        end

        [s, o]
      end.compact.to_h
      data
    end

    def generate_sitemap published: true
      urls = {}

      # do feeds separately
      feeds = all_of_type RDF::Vocab::DCAT.Distribution
      #feeds.select! { |f| published? f } if published
      feeds.each do |f|
        uri = canonical_uri(f)
        f = generate_atom_feed f, published: published, related: feeds
        mt = f.at_xpath('/atom:feed/atom:updated[1]/text()',
          { atom: 'http://www.w3.org/2005/Atom' })
        urls[uri] = { [{ [uri.to_s] => :loc }, { [mt] => :lastmod }] => :url }
      end

      # build up hash of urls
      all_internal_docs(published: published).each do |doc|
        next if asserted_types(doc).include? RDF::Vocab::FOAF.Image
        uri  = canonical_uri(doc)
        next unless uri.authority && @base && uri.authority == base.authority
        mods = objects_for(doc, [RDF::Vocab::DC.created,
          RDF::Vocab::DC.modified, RDF::Vocab::DC.issued],
          datatype: RDF::XSD.dateTime).sort
        nodes = [{ [uri.to_s] => :loc }]
        nodes << { [mods[-1].to_s] => :lastmod } unless mods.empty?
        urls[uri] = { nodes => :url }
      end

      urls = urls.sort.map { |_, v| v }

      markup(spec: { urls => :urlset,
        xmlns: 'http://www.sitemaps.org/schemas/sitemap/0.9' }).document
    end

    def write_sitemap published: true
      sitemap = generate_sitemap published: published
      file    = @config[:sitemap] || '.well-known/sitemap.xml'
      target  = @config[published ? :target : :private]
      target.mkpath unless target.directory?

      fh = (target + file).open(?w)
      sitemap.write_to fh
      fh.close
    end

    # generate atom feed

    #
    def all_internal_docs published: true, exclude: []
      # find all UUIDs that are documents
      docs = all_of_type(RDF::Vocab::FOAF.Document,
        exclude: exclude).select { |x| x =~ /^urn:uuid:/ }

      # prune out all but the published documents if specified
      if published
        p = RDF::Vocab::BIBO.status
        o = RDF::Vocabulary.find_term(
          'http://purl.org/ontology/bibo/status/published')
        docs = docs.select do |s|
          @graph.has_statement? RDF::Statement(s, p, o)
        end
      end
      
      docs
    end

    def indexed? subject
      subject = coerce_resource subject
      indexed = objects_for subject, RDF::SAK::CI.indexed,
        only: :literal, datatype: RDF::XSD.boolean
      # assume the subject is indexed but we are looking for explicit
      # presence of `false` (ie explicit `false` overrides explicit
      # `true`). values like ci:indexed -> "potato" are ignored.
      indexed.empty? or indexed.none? { |f| f.object == false }
    end

    def generate_atom_feed id, published: true, related: []
      raise 'ID must be a resource' unless id.is_a? RDF::Resource

      # prepare relateds
      raise 'related must be an array' unless related.is_a? Array
      related -= [id]

      # feed audiences
      faudy = audiences_for id
      faudn = audiences_for id, invert: true
      faudy -= faudn

      warn 'feed %s has audiences %s and non-audiences %s' %
        [id, faudy.inspect, faudn.inspect]

      docs = all_internal_docs published: published

      # now we create a hash keyed by uuid containing the metadata
      authors = {}
      titles  = {}
      dates   = {}
      entries = {}
      latest  = nil
      docs.each do |uu|
        # basically make a jsonld-like structure
        #rsrc = struct_for uu

        # skip unless the entry is indexed
        next unless indexed? uu
        
        # get audiences
        audy = audiences_for uu, proximate: true
        audn = audiences_for uu, proximate: true, invert: true
        audy -= audn

        warn 'doc %s has audiences %s and non-audiences %s' %
          [uu, audy.inspect, audn.inspect]

        # we begin by assuming the document is *not* included in the
        # feed, and then we try to prove otherwise
        skip = true
        if audy.empty?
          # if both the feed and the document audiences are
          # unspecified, then include it, as both are for "everybody"
          skip = false if faudy.empty?
        elsif faudy.empty?
          # if the feed is for everybody but the document is for
          # somebody in particular, only include it if its audience is
          # in the list of the feed's non-audiences
          skip = false unless (audy - faudn).empty?
        else
          # now we deal with the case where both the feed and the
          # document have explicit audiences

          # if the document hasn't been explicitly excluded by the
          # feed, then include it if it has explicitly been included
          skip = false if !(audy - faudn).empty? && !(faudy & audy).empty?
        end

        next if skip

        canon = URI.parse(canonical_uri(uu).to_s)
        
        xml = { '#entry' => [
          { '#link' => nil, rel: :alternate, href: canon, type: 'text/html' },
          { '#id' => uu.to_s }
        ] }

        # get published date first
        published = (objects_for uu,
                     [RDF::Vocab::DC.issued, RDF::Vocab::DC.created],
                     datatype: RDF::XSD.dateTime)[0]
        
        # get latest updated date
        updated = (objects_for uu, RDF::Vocab::DC.modified,
                   datatype: RDF::XSD.dateTime).sort[-1]
        updated ||= published || RDF::Literal::DateTime.new(DateTime.now)
        updated = Time.parse(updated.to_s).utc
        latest = updated if !latest or latest < updated

        xml['#entry'].push({ '#updated' => updated.iso8601 })

        if published
          published = Time.parse(published.to_s).utc
          xml['#entry'].push({ '#published' => published.iso8601 })
          dates[uu] = [published, updated]
        else
          dates[uu] = [updated, updated]
        end

        # get author(s)
        al = []
        authors_for(uu).each do |a|
          unless authors[a]
            n = label_for a
            x = authors[a] = { '#author' => [{ '#name' => n[1].to_s }] }

            if hp = objects_for(a, RDF::Vocab::FOAF.homepage,
                                only: :resource).sort.first
              hp = canonical_uri hp
            end

            hp ||= canonical_uri a
            
            x['#author'].push({ '#uri' => hp.to_s }) if hp
          end

          al.push authors[a]
        end

        xml['#entry'] += al unless al.empty?

        # get title (note unshift)
        if (t = label_for uu)
          titles[uu] = t[1].to_s
          xml['#entry'].unshift({ '#title' => t[1].to_s })
        else
          titles[uu] = uu.to_s
        end
        
        # get abstract
        if (d = label_for uu, desc: true)
          xml['#entry'].push({ '#summary' => d[1].to_s })
        end
        
        entries[uu] = xml
      end

      # note we overwrite the entries hash here with a sorted array
      entrycmp = -> a, b {
        # first we sort by published date
        p = dates[a][0] <=> dates[b][0]
        # if the published dates are the same, sort by updated date
        u = dates[a][1] <=> dates[b][1]
        # to break any ties, finally sort by title
        p == 0 ? u == 0 ? titles[a] <=> titles[b] : u : p }
      entries = entries.values_at(
        *entries.keys.sort { |a, b| entrycmp.call(a, b) })
      # ugggh god forgot the asterisk and lost an hour

      # now we punt out the doc

      preamble = [
        { '#id' => id.to_s },
        { '#updated' => latest.iso8601 },
        { '#generator' => 'RDF::SAK', version: RDF::SAK::VERSION,
          uri: "https://github.com/doriantaylor/rb-rdf-sak" },
        { nil => :link, rel: :self, type: 'application/atom+xml',
          href: canonical_uri(id) },
        { nil => :link, rel: :alternate, type: 'text/html',
          href: @base },
      ] + related.map do |r|
        { nil => :link, rel: :related, type: 'application/atom+xml',
         href: canonical_uri(r) }
      end

      if (t = label_for id)
        preamble.unshift({ '#title' => t[1].to_s })
      end

      if (r = @graph.first_literal [id, RDF::Vocab::DC.rights, nil])
        rh = { '#rights' => r.to_s, type: :text }
        rh['xml:lang'] = r.language if r.has_language?
        preamble.push rh
      end

      markup(spec: { '#feed' => preamble + entries,
        xmlns: 'http://www.w3.org/2005/Atom' }).document
    end

    def write_feeds type: RDF::Vocab::DCAT.Distribution, published: true
      feeds = all_of_type type
      target = @config[published ? :target : :private]
      feeds.each do |feed|
        tu  = URI(feed.to_s)
        doc = generate_atom_feed feed, published: published, related: feeds
        fh  = (target + "#{tu.uuid}.xml").open('w')
        doc.write_to fh
        fh.close
      end
    end

    # generate sass palettes

    # generate rewrite map(s)
    def generate_rewrite_map published: false, docs: nil
      docs ||= reachable published: published
      base = URI(@base.to_s)
      rwm  = {}
      docs.each do |doc|
        tu = URI(doc.to_s)
        cu = canonical_uri doc, rdf: false
        next unless tu.respond_to?(:uuid) and cu.respond_to?(:request_uri)

        # skip external links obvs
        next unless base.route_to(cu).relative?

        # skip /uuid form
        cp = cu.request_uri.delete_prefix '/'
        next if cu.host == base.host and tu.uuid == cp
        
        rwm[cp] = tu.uuid
      end

      rwm
    end

    # give me all UUIDs of all documents, filter for published if
    # applicable
    # 
    # find the "best" (relative) URL for the UUID and map the pair
    # together
    def generate_uuid_redirect_map published: false, docs: nil
      docs ||= reachable published: published

      base = URI(@base.to_s)

      # keys are /uuid, values are 
      out = {}
      docs.each do |doc|
        tu = URI(doc.to_s)
        cu = canonical_uri doc, rdf: false
        next unless tu.respond_to?(:uuid) and cu.respond_to?(:request_uri)

        # skip /uuid form
        cp = cu.request_uri.delete_prefix '/'
        next if cu.host == base.host && tu.uuid == cp

        # all redirect links are absolute
        out[tu.uuid] = cu.to_s
      end
      out
    end

    # find all URIs/slugs that are *not* canonical, map them to slugs
    # that *are* canonical
    def generate_slug_redirect_map published: false, docs: nil
      docs ||= reachable published: published
      base = URI(@base.to_s)

      # for redirects we collect all the docs, plus all their URIs,
      # separate canonical from the rest

      # actually an easy way to do this is just harvest all the
      # multi-addressed docs, remove the first one, then ask for the
      # canonical uuid back,

      fwd = {}
      rev = {}
      out = {}

      docs.each do |doc|
        uris  = canonical_uri doc, unique: false, rdf: false
        canon = uris.shift
        next unless canon.respond_to? :request_uri

        # cache the forward direction
        fwd[doc] = canon

        unless uris.empty?
          uris.each do |uri|
            next unless uri.respond_to? :request_uri
            next if canon == uri
            next unless base.route_to(uri).relative?

            # warn "#{canon} <=> #{uri}"

            requri = uri.request_uri.delete_prefix '/'
            next if requri == '' ||
              requri =~ /^[0-9a-f]{8}(?:-[0-9a-f]{4}){4}[0-9a-f]{8}$/

            # cache the reverse direction
            rev[uri] = requri
          end
        end
      end

      rev.each do |uri, requri|
        if (doc = canonical_uuid(uri, published: published)) and
            fwd[doc] and fwd[doc] != uri
          out[requri] = fwd[doc].to_s
        end
      end

      out
    end

    # you know what, it's entirely possible that these ought never be
    # called individually and the work to get one would duplicate the
    # work of getting the other, so maybe just do 'em both at once

    def generate_redirect_map published: false, docs: nil
      generate_uuid_redirect_map(published: published, docs: docs).merge(
        generate_slug_redirect_map(published: published, docs: docs))
    end

    def generate_gone_map published: false, docs: nil
      # published is a no-op for this one because these docs are by
      # definition not published
      docs ||= reachable published: false
      p    = RDF::Vocab::BIBO.status
      base = URI(@base.to_s)
      out  = {}
      docs.select { |s|
        @graph.has_statement? RDF::Statement(s, p, CI.retired) }.each do |doc|
        canon = canonical_uri doc, rdf: false
        next unless base.route_to(canon).relative?
        canon = canon.request_uri.delete_prefix '/'
        # value of the gone map doesn't matter
        out[canon] = canon
      end

      out
    end

    # private?

    def map_location type
      # find file name in config
      fn = @config[:maps][type] or return

      # concatenate to target directory
      @config[:target] + fn
    end

    # private?

    def write_map_file location, data
      # open file
      fh = File.new location, 'w'
      data.sort.each { |k, v| fh.write "#{k}\t#{v}\n" }
      fh.close # return value is return value from close
    end

    # public again

    def write_rewrite_map published: false, docs: nil
      data = generate_rewrite_map published: published, docs: docs
      loc  = map_location :rewrite
      write_map_file loc, data
    end

    def write_redirect_map published: false, docs: nil
      data = generate_redirect_map published: published, docs: docs
      loc  = map_location :redirect
      write_map_file loc, data
    end

    def write_gone_map published: false, docs: nil
      data = generate_gone_map published: published, docs: docs
      loc  = map_location :gone
      write_map_file loc, data
    end

    def write_maps published: true, docs: nil
      docs ||= reachable published: false
      # slug to uuid (internal)
      write_rewrite_map docs: docs
      # uuid/slug to canonical slug (308)
      write_redirect_map docs: docs
      # retired slugs/uuids (410)
      write_gone_map docs: docs
      true
    end

    # generate an alphabetized list as an xhtml document with metadata
    #
    # @param subject [RDF::Resource]
    # @param fwd [RDF::URI,Array] forward predicate or array thereof
    # @param rev [RDF::URI,Array] reverse predicate or array thereof
    # @yield [subject, struct] pass a block to construct
    # @yieldparam subject [RDF::Resource] the subject
    # @yieldparam struct [Hash] the predicate-object struct of the subject
    # @return [Nokogiri::XML::Document] the finished document
    #
    def alphabetized_list subject, fwd: nil, rev: nil, published: true,
        preamble: RDF::Vocab::DC.description, ucache: {}, scache: {}, &block
      raise ArgumentError,
        'We need a block to render the markup! it is not optional!' unless block

      # plump these out
      fwd = fwd ? fwd.respond_to?(:to_a) ? fwd.to_a : [fwd] : []
      rev = rev ? rev.respond_to?(:to_a) ? rev.to_a : [rev] : []

      raise ArgumentError, 'Must have either a fwd or a rev defined' if
        fwd.empty? and rev.empty?

      # first we get them, then we sort them
      frels = {} # forward relations
      rrels = {} # reverse relations
      alpha = {} # alphabetical map
      seen  = {} # flat map

      # a little metaprogramming to get forward and reverse
      [[fwd, [frels, rrels], :objects_for,  [subject, fwd]],
       [rev, [rrels, frels], :subjects_for, [rev, subject]]
      ].each do |pa, rel, meth, args|
        next if pa.empty?

        send meth, *args, only: :resource do |n, pfwd, prev|
          # skip if we've already got this (eg with fwd then reverse)
          next if seen[n]
          # make a dummy so as not to incur calling published? multiple times
          seen[n] = {}
          # now we set the real struct and get the label
          st = seen[n] = struct_for n, uuids: true, inverses: true,
            ucache: ucache, scache: scache

          # now check if it's published
          next if published and
            rdf_type?(n, RDF::Vocab::FOAF.Document, struct: st) and
            not published?(n)

          # now the relations to the subject
          rel.map { |r| r[n] ||= Set.new }
          rel.first[n] |= pfwd
          rel.last[n]  |= prev

          lab = (label_for(n, candidates: st) || [nil, n]).last.value.strip

          lab.gsub!(/\A[[:punct:][:space:]]*(?:An?|The)[[:space:]]+/i, '')

          # get the index character which will be unicode, hence these
          # festive character classes
          char = if match = /\A[[:punct:][:space:]]*
                   (?:([[:digit:]])|([[:word:]])|([[:graph:]]))
                   /x.match(lab)
                   match[2] ? match[2].upcase : ?#
                 else
                  ?#
                 end

          # add { node => struct } under this heading
          (alpha[char] ||= {})[n] = st
        end
      end

      # up until now we didn't need this; also add it to seen
      struct = seen[subject] ||= struct_for subject,
        uuids: true, inverses: true, ucache: ucache, scache: scache

      # obtain the base and prefixes and generate the node spec
      base = canonical_uri subject, rdf: false
      spec = alpha.sort { |a, b| a.first <=> b.first }.map do |key, structs|
        # sort these and run the block
        sections = structs.sort do |a, b|
          al = label_for(a.first, candidates: a.last).last
          bl = label_for(b.first, candidates: b.last).last
          al <=> bl
        end.map do |s, st|
          # now we call the block
          fr = frels[s].to_a if frels[s] and !frels[s].empty?
          rr = rrels[s].to_a if rrels[s] and !rrels[s].empty?
          # XXX it may be smart to just pass all the structs in
          block.call s, fr, rr, st, base, seen
        end.compact

        { ([{[key] => :h2 }] + sections) => :section }
      end


      # now we get the page metadata
      pfx   = prefix_subset prefixes, seen
      abs   = label_for(subject, candidates: struct, desc: true)
      mn    = abs ? { abs.last => :description } : {} # not an element!
      meta  = head_meta(subject, struct: struct, meta_names: mn,
                        vocab: XHV) + generate_twitter_meta(subject)
      links = head_links subject, struct: struct, vocab: XHV,
        ignore: seen.keys, rev: RDF::SAK::CI.document
      types = abbreviate asserted_types(subject, struct: struct)
      title = if t = label_for(subject, candidates: struct)
                [t[1].to_s, abbreviate(t[0])]
              end

      if abs
        para = { [abs.last.to_s] => :p, property: abbreviate(abs.first) }
        para['xml:lang'] = abs.last.language if abs.last.language?
        para[:datatype]  = abs.last.datatype if abs.last.datatype?
        spec.unshift para
      end

      xhtml_stub(base: base, title: title, transform: @config[:transform],
        prefix: pfx, vocab: XHV, link: links, meta: meta,
        attr: { about: '', typeof: types }, content: spec
      ).document
    end

    # whoops lol we forgot the book list

    def reading_lists published: true
      out = all_of_type RDF::Vocab::SiocTypes.ReadingList
      return out unless published
      out.select { |r| published? r }
    end

    LISTOP = -> opmap, seen, published do
      # we just sort this so it's consistent
      opmap.sort { |a, b| a.first <=> b.first }.map do |o, preds|
        li = RDF::List.new(subject: o, graph: @graph).to_a.map do |item|
          next if seen[item] or (published and published?(item))
          st = seen[item] = struct_for item
          lp, lo = (label_for(item, candidates: st) || [nil, item])
          typ = asserted_types item, struct: st
          #a = { [lab.last] => :span, about: item, typeof: abbreviate(typ),
          #  property: abbreviate(lab.first) }
          a = [lo.value]
          dd = { a => :li, about: item }
          dd[:typeof] = abbreviate(typ) if typ
          # literal stuff
          dd[:property]  = abbreviate(lp) if lp
          dd[:datatype]  = abbreviate(lo.datatype) if lo.datatype?
          dd['xml:lang'] = lo.language if lo.language?
          dd
        end.compact
        { { li => :ul, rel: abbreviate(preds), inlist: '' } => :dd }
      end.compact
    end

    REGOP  = -> opmap, seen, published do
      opmap.map { |x| x + [struct_for(x.first, uuids: true)] }.sort do |a, b|
        al = (label_for(a.first, candidates: a.last) || [nil, a.first])
        bl = (label_for(b.first, candidates: b.last) || [nil, b.first])
        al.last.value <=> bl.last.value
      end.map do |item, preds, struct|
        next if seen[item] or (published and published?(item))
        st = seen[item] = struct_for item
        lab = label_for item, candidates: st
        typ = asserted_types item, struct: st
        a = { [lab.last] => :span, about: item, typeof: abbreviate(typ),
          property: abbreviate(lab.first) }
        { a => :dd, rel: abbreviate(preds) }
      end.compact
    end

    DLSPEC = {
      'By:' => {
        RDF::Vocab::BIBO.authorList      => LISTOP,
        RDF::Vocab::DC.creator           => REGOP,
      },
      'With:' => {
        RDF::Vocab::BIBO.contributorList => LISTOP,
        RDF::Vocab::DC.contributor       => REGOP,
      },
      'Edited by:' => {
        RDF::Vocab::BIBO.editorList      => LISTOP,
        RDF::Vocab::BIBO.editor          => REGOP,
      },
      'Translated by:' => {
        RDF::Vocab::BIBO.translator      => REGOP,
      },
    }

    def generate_reading_list subject, published: true

      here = Set[subject]

      # uggh put these somewhere
      preds = {
        hp:    predicate_set(RDF::Vocab::DC.hasPart),
        sa:    predicate_set(RDF::RDFS.seeAlso),
        canon: predicate_set([RDF::OWL.sameAs, CI.canonical]),
        ref:   predicate_set(RDF::Vocab::DC.references),
        al:    predicate_set(RDF::Vocab::BIBO.contributorList),
        cont:  predicate_set(RDF::Vocab::DC.contributor),
      }

      alphabetized_list subject, fwd: RDF::Vocab::DC.hasPart,
        published: published do |s, fp, rp, struct, base, seen|

        here << s


        # let's just do this first
        kids = []
        sec  = { kids => :section, resource: s.value }
        if types = asserted_types(s, struct: struct)
          sec[:typeof] = abbreviate(types)
        end
        sec[:rel] = abbreviate(fp) if fp
        sec[:rev] = abbreviate(rp) if rp

        lp, lo = label_for(s, candidates: struct)
        lh = { property: abbreviate(lp) }
        lh[:datatype]  = lo.datatype if lo.datatype?
        lh['xml:lang'] = lo.language if lo.language?

        # rdfs:seeAlso -> amazon (or whatever) link
        sa = find_in_struct(struct, RDF::RDFS.seeAlso, invert: true)
        if sa and !sa.empty?
          sao, sap = sa.sort { |a, b| a.first <=> b.first }.first
          sap = abbreviate(sap, prefixes: prefixes)

          # lol add amazon affil tag
          if /^(www\.)?amazon\./i.match? sao.host and
              amzn = @config.dig(:plugin, :amazon)
            qv = (sao.query_values(Array) || []).reject { |x| x.first == 'tag' }
            qv << ['tag', amzn]
            sao = sao.dup
            sao.query_values = qv
          end
            
          span = { [lo.value] => :span, about: s.value }.merge lh
          kids << {
            { span => :a, rel: abbreviate(sap), href: sao.value } => :h3 }
        else
          kids << { [lo.value] => :h3 }.merge(lh)
        end


        # now
        dli = DLSPEC.map do |dtl, ops|
          lseen = {}

          dd = ops.map do |p, op|
            opmap = find_in_struct struct, p, invert: true
            instance_exec(opmap, lseen, published, &op)
          end.flatten(1)

          seen.merge! lseen

          [{ [dtl] => :dt }] + dd unless dd.empty?
        end.compact.flatten(1)

        # now do references

        # everything that references either the subject or one of its seeAlsos
        # XXX think of a better way to accumulate
        structs = {}
        refs = ([s] + sa.keys + sa.keys.map { |k|
                  subjects_for(preds[:canon], k, only: :uri, entail: false)
                }).flatten.uniq.map do |u|
          # get the subjects that point
          subjects_for(preds[:ref], u, only: :uri) do |rs, pfwd, prev|
            # maybe this structure will correctly communicate upstream
            unless structs[rs] or (published and !published?(rs))
              structs[rs] = struct_for(rs)
              [rs, [pfwd, prev]]
            end
          end.compact.to_h
        end.reduce({}) { |hout, hin| hout.merge! hin }.to_a.sort do |a, b|
          sa = structs[a.first]
          sb = structs[b.first]
          al = (label_for(a.first, candidates: sa) || [nil, a.first])
          bl = (label_for(a.first, candidates: sb) || [nil, b.first])
        #   warn [al.last.to_s.upcase, bl.last.to_s.upcase].inspect
          al.last.to_s.upcase <=> bl.last.to_s.upcase
        end.map do |k, v|
          st = structs[k]
          pfwd, prev = *v
          uri = canonical_uri k, rdf: false
          lp, lo = (label_for(k, candidates: st) || [nil, k])

          if %w[http https].include? uri.scheme
            span = if lp 
                     x = { [lo.to_s] => :span, property: abbreviate(lp) }
                     x[:datatype]  = lo.datatype if lo.datatype?
                     x['xml:lang'] = lo.language if lo.language?
                     x
                   else
                     [lo.to_s]
                   end
            x = { span => :a, href: base.route_to(uri) }
            if typ = asserted_types(k, struct: st)
              x[:typeof] = abbreviate(typ)
            end
            x[:rev] = abbreviate(pfwd) unless pfwd.empty?
            x[:rel] = abbreviate(prev) unless prev.empty?
            { x => :dd }
          else
            x = { [lo.to_s] => :dd, resource: uri }
            if typ = asserted_types(k, struct: st)
              x[:typeof] = abbreviate(typ)
            end
            x[:rev] = abbreviate(pfwd) unless pfwd.empty?
            x[:rel] = abbreviate(prev) unless prev.empty?
            x
          end
        end

        # warn refs.inspect

        unless refs.empty?
          refs.unshift({ ['Referenced by:'] => :dt })
          dli += refs
        end

        kids << { dli => :dl } unless dli.empty?

        sec
      end
    end

    def write_reading_lists published: true
      reading_lists(published: published).each do |rl|
        tu  = URI(rl.to_s)
        states = [true]
        states << false unless published
        states.each do | state|
          doc = generate_reading_list rl, published: state
          dir = @config[state ? :target : :private]
          (dir + "#{tu.uuid}.xml").open('wb') { |fh| doc.write_to fh }
        end
      end
    end

    DSD_SEQ = %i[characters words blocks sections
      min low-quartile median high-quartile max mean sd].freeze
    TH_SEQ = %w[Document Abstract Created Modified Characters Words Blocks 
      Sections Min Q1 Median Q3 Max Mean SD].map { |t| { [t] => :th } }

    def generate_stats published: true
      out = {}
      all_of_type(QB.DataSet).map do |s|
        base  = canonical_uri s, rdf: false
        types = abbreviate asserted_types(s)
        title = if t = label_for(s)
                  [t[1].to_s, abbreviate(t[0])]
                end
        cache = {}
        subjects_for(QB.dataSet, s, only: :resource).each do |o|
          if d = objects_for(o, CI.document, only: :resource).first
            if !published or published?(d)
              # include a "sort" time that defaults to epoch zero
              c = cache[o] ||= {
                doc: d, stime: Time.at(0).getgm, struct: struct_for(o) }

              if t = label_for(d)
                c[:title] = t
              end
              if a = label_for(d, desc: true)
                c[:abstract] = a
              end
              if ct = objects_for(d,
                RDF::Vocab::DC.created, datatype: RDF::XSD.dateTime).first
                c[:stime] = c[:ctime] = ct.object.to_time.getgm
              end
              if mt = objects_for(d,
                RDF::Vocab::DC.modified, datatype:RDF::XSD.dateTime)
                c[:mtime] = mt.map { |m| m.object.to_time.getgm }.sort
                c[:stime] = c[:mtime].last unless mt.empty?
              end
            end
          end
        end

        # sort lambda closure
        sl = -> a, b do
          x = cache[b][:stime] <=> cache[a][:stime]
          return x unless x == 0
          x = cache[b][:ctime] <=> cache[a][:ctime]
          return x unless x == 0
          ta = cache[a][:title] || Array.new(2, cache[a][:uri])
          tb = cache[b][:title] || Array.new(2, cache[b][:uri])
          ta[1].to_s <=> tb[1].to_s
        end

        rows = []
        cache.keys.sort(&sl).each do |k|
          c = cache[k]
          href = base.route_to canonical_uri(c[:doc], rdf: false)
          dt = abbreviate asserted_types(c[:doc])
          uu = URI(k.to_s).uuid
          nc = UUID::NCName.to_ncname uu, version: 1
          tp, tt = c[:title] || []
          ab = if c[:abstract]
                 { [c[:abstract][1].to_s] => :th, about: href,
                  property: abbreviate(c[:abstract].first) }
               else
                 { [] => :th }
               end
          
          td = [{ { { [tt.to_s] => :span, property: abbreviate(tp) } => :a,
            rel: 'ci:document', href: href } => :th },
            ab,
            { [c[:ctime].iso8601] => :th, property: 'dct:created',
             datatype: 'xsd:dateTime', about: href, typeof: dt },
            { c[:mtime].reverse.map { |m| { [m.iso8601] => :span,
               property: 'dct:modified', datatype: 'xsd:dateTime' } } => :th,
              about: href
            },
          ] + DSD_SEQ.map do |f|
            h = []
            x = { h => :td }
            p = CI[f]
            if y = c[:struct][p] and !y.empty?
              h << y = y.first
              x[:property] = abbreviate p
              x[:datatype] = abbreviate y.datatype if y.datatype?
            end
            x
          end
          rows << { td => :tr, id: nc, about: "##{nc}",
            typeof: 'qb:Observation' }
        end

        # XXX add something to the vocab so this can be controlled in the data
        xf = config.dig(:stats, :transform) || config[:transform]

        out[s] = xhtml_stub(base: base, title: title,
          transform: xf, attr: { about: '', typeof: types },
          prefix: prefixes, content: {
            [{ [{ [{ ['About'] => :th, colspan: 4 },
                { ['Counts'] => :th, colspan: 4 },
                { ['Words per Block'] => :th, colspan: 7 }] => :tr },
              { TH_SEQ => :tr } ] => :thead },
             { rows => :tbody, rev: 'qb:dataSet' }] => :table }).document
      end

      out
    end

    def write_stats published: true
      target = @config[published ? :target : :private]
      target.mkpath unless target.directory?
      generate_stats(published: published).each do |uu, doc|
        bn = URI(uu.to_s).uuid + '.xml'
        fh = (target + bn).open ?w
        doc.write_to fh
        fh.flush
        fh.close
      end
    end


    # This will generate an (X)HTML+RDFa page containing either a
    # SKOS concept scheme or a collection, ordered or otherwise.
    # 
    # XXX later on we should consider conneg for languages
    #
    #
    def generate_concept_scheme subject, published: true, fragment: false
      # stick some logic here to sort out what kind of thing it is
      # (concept scheme, collection, ordered collection)

      # run this once
      rels = {
        broader: 'Has Broader',
        narrower: 'Has Narrower',
        related: 'Has Related' }.map do |k, v|
        [predicate_set(RDF::Vocab::SKOS[k]), v]
      end

      ucache = {}
      scache = {}
      struct = struct_for subject, uuids: true, ucache: ucache, scache: scache
      neighbours = { subject => struct }

      types = asserted_types(subject, struct: struct)

      if type_is?(types, RDF::Vocab::SKOS.OrderedCollection)
        # sort 
        list = if head = objects_for(subject, RDF::Vocab::SKOS.memberList,
                                     only: :blank).sort.first
                 RDF::List.new(subject: head, graph: @graph).to_a.map do |s|
                   next if published and not published?(s)
                   neighbours[s] ||= {}
                   { [] => :script, type: 'application/xhtml+xml',
                    src: canonical_uri(s) }
                 end.compact
               end

        spec = [{ list => :article, inlist: '',
                rel: abbreviate(RDF::Vocab::SKOS.memberList) }]

        abs   = label_for(subject, candidates: struct, desc: true)
        mn    = abs ? { abs.last => :description } : {} # not an element!
        meta  = head_meta(subject, struct: struct, meta_names: mn,
                          vocab: XHV) + generate_twitter_meta(subject)
        links = head_links subject, struct: struct, vocab: XHV,
          ignore: neighbours.keys
        title = if t = label_for(subject, candidates: struct)
                  [t[1].to_s, abbreviate(t[0])]
                end
        if abs
          para = { [abs.last.to_s] => :p, property: abbreviate(abs.first) }
          para['xml:lang'] = abs.last.language if abs.last.language?
          para[:datatype]  = abs.last.datatype if abs.last.datatype?
          spec.unshift para
        end

        pfx = prefix_subset prefixes, neighbours

        xhtml_stub(base: base, title: title, transform: @config[:transform],
          prefix: pfx, vocab: XHV, link: links, meta: meta,
          attr: { about: '', typeof: abbreviate(types) }, content: spec
        ).document
      elsif type_is?(types, RDF::Vocab::SKOS.Collection)
        # make a flat list of just transclusions
        alphabetized_list subject, fwd: RDF::Vocab::SKOS.member,
          published: published,
          ucache: ucache, scache: scache do |s, fp, rp, struct, base, seen|
            # just return the sections i guess lol
            { [''] => :script, type: 'application/xhtml+xml',
              src: canonical_uri(s), rel: abbreviate(fp) }
        end
      elsif type_is?(types, RDF::Vocab::SKOS.ConceptScheme)
        # note i'm not sure about this whole 'seen' business

        # WOOF lol
        alphabetized_list subject, rev: RDF::Vocab::SKOS.inScheme,
          published: published,
          ucache: ucache, scache: scache do |s, fp, rp, struct, base, seen|

          # may as well bag this while we're at it
          neighbours[s] ||= struct

          # sequence of elements beginning with the heading
          el = begin
                 lp, lo = label_for(s, candidates: struct)
                 [literal_tag(lo, name: :h3, property: lp, prefixes: prefixes)]
               end

          # now we do definitions
          el += find_in_struct(struct, RDF::Vocab::SKOS.definition,
                               entail: true, invert: true).sort do |a, b|
              cmp_resource a.first, b.first
          end.map do |o, ps|
            rel = abbreviate(ps)
            if o.uri?
              { { [''] => :script, type: 'application/xhtml+xml',
                 src: canonical_uri(o) } => :p, rel: rel }
            else
              para = { [o.value] => :p, property: rel }
              para['xml:lang'] = para[:lang] = o.language if o.language?
              para[:datatype] = o.datatype if o.datatype?
              para
            end.compact
          end

          # do alternate labels
          dl = find_in_struct(struct, RDF::Vocab::SKOS.altLabel,
                              entail: true, invert: true).sort do |a, b|
            a.first <=> b.first
          end.map do |o, ps|
            next unless o.literal?

            dd = { [o.value] => :dd, property: abbreviate(ps) }
            dd[:'xml:lang'] = dd[:lang] = o.language if o.language?
            dd[:datatype] = o.datatype if o.datatype?
            dd
          end.compact
          dl.unshift({ ['Also known as'] => :dt }) unless dl.empty?

          # do relations
          dl += rels.map do |pred, dt|
            # this will give us a map of neighbours to the predicates
            # actually used to relate them
            objs = find_in_struct struct, pred, invert: true
            # plump up the structs
            objs.keys.each do |k|
              neighbours[k] ||= struct_for(k,
                uuids: true, inverses: true, ucache: ucache, scache: scache)
            end

            unless objs.empty?
              [{ [dt] => :dt }] + objs.sort do |a, b|
                # XXX there is a cmp_label but it is dumb
                al = (label_for(a.first, candidates: neighbours[a.first]) ||
                      [nil, a.first]).last
                bl = (label_for(b.first, candidates: neighbours[b.first]) ||
                      [nil, b.first]).last
                al.value <=> bl.value
              end.map do |o, ps|
                # XXX this is where i would like canonical_uri to
                # just "know" to do this (also this will fail if
                # this is not a uuid)
                id = UUID::NCName.to_ncname_64(o.value.dup, version: 1)
                olp, olo = label_for(o, candidates: neighbours[o])
                href = base.dup
                href.fragment = id
                { link_tag(href, rel: ps, base: base,
                  typeof: asserted_types(o, struct: struct),
                  property: olp, label: olo, prefixes: prefixes ) => :dd }
              end
            end
          end.compact

          # do backreferences

          op = graph.query(object: s).to_a.select do |stmt|
            sj = stmt.subject
            sj.uri? and !neighbours[sj] and (!published or published?(sj))
          end.reduce({}) do |hash, stmt|
            sj = stmt.subject
            neighbours[sj] ||= struct_for(sj,
              uuids: true, inverses: true, ucache: ucache, scache: scache)
            (hash[sj] ||= []) << stmt.predicate
            hash
          end

          unless op.empty?
            dl << { ['Referenced By'] => :dt }
            op.sort do |a, b|
              al = (label_for(a.first,
                candidates: neighbours[a.first]) || [a.first]).last
              bl = (label_for(b.first,
                candidates: neighbours[b.first]) || [b.first]).last
              al.value.upcase <=> bl.value.upcase
            end.each do |sj, ps|
              st   = neighbours[sj]
              href = canonical_uri sj
              olp, olo = label_for(sj, candidates: st)

              dl << { link_tag(href, rev: ps, base: base,
                typeof: asserted_types(sj, struct: st),
                property: olp, label: olo, prefixes: prefixes) => :dd }
            end
          end

          # add to set
          el << { dl => :dl } unless dl.empty?

          # id  = UUID::NCName.to_ncname_64(s.value.dup, version: 1)
          id = canonical_uri(s)
          id = id.fragment || UUID::NCName.to_ncname_64(s.value.dup, version: 1)
          sec = { el => :section, id: id, resource: "##{id}" }
          if typ = asserted_types(s, struct: struct)
            sec[:typeof] = abbreviate(typ)
          end
          sec[:rel] = abbreviate(fp) if rp
          sec[:rev] = abbreviate(rp) if rp
          sec
        end
      else
        raise ArgumentError,
          "Subject #{subject} must be some kind of SKOS entity"
      end
    end

    def write_concept_schemes published: true
      # XXX i should really standardize these `write_whatever` thingies
      schemes = [RDF::Vocab::SKOS.ConceptScheme, RDF::Vocab::SKOS.Collection]
      all_of_type(schemes).each do |list|
        next if published and !published?(list)
        list = canonical_uuid(list) or next
        uuid = URI(list.to_s)
        states = [true]
        states << false unless published
        states.each do |state|
          doc = generate_concept_scheme list, published: state
          dir = @config[state ? :target : :private]
          dir.mkdir unless dir.exist?
          (dir + "#{uuid.uuid}.xml").open('wb') { |fh| doc.write_to fh }
        end
      end
    end

    # - io stuff -

    # Locate the file in the source directory associated with the given URI.
    #
    # @param [RDF::URI, URI, :to_s] the URI requested
    # 
    # @return [Pathname] of the corresponding file or nil if no file was found.
    #
    def locate uri
      uri = coerce_resource uri

      base = URI(@base.to_s)

      tu = URI(uri) # copy of uri for testing content
      unless tu.scheme == 'urn' and tu.nid == 'uuid'
        raise "could not find UUID for #{uri}" unless uuid = canonical_uuid(uri)
        tu = URI(uri = uuid)
      end

      # xxx bail if the uri isn't a subject in the graph

      candidates = [@config[:source] + tu.uuid]

      # try all canonical URIs
      (canonical_uri uri, unique: false, slugs: true).each do |u|
        u = URI(u.to_s)
        next unless u.hostname == base.hostname
        p = CGI.unescape u.path[/^\/*(.*?)$/, 1]
        candidates.push(@config[:source] + p)
      end

      # warn candidates

      files = candidates.uniq.map do |c|
        Pathname.glob(c.to_s + '{,.*,/index{,.*}}')
      end.reduce(:+).reject do |x|
        x.directory? or RDF::SAK::MimeMagic.by_path(x).to_s !~ 
          /.*(?:markdown|(?:x?ht|x)ml).*/i
      end.uniq

      #warn files

      # XXX implement negotiation algorithm
      return files.first

      # return the filename from the source
      # nil
    end

    # Visit (open) the document at the given URI.
    # 
    # @param uri [RDF::URI, URI, :to_s]
    # 
    # @return [RDF::SAK::Context::Document] or nil

    def visit uri
      uri  = canonical_uuid uri
      path = locate uri
      return unless path
      Document.new self, uri, uri: canonical_uri(uri), doc: path
    end

    # resolve documents from source
    def resolve_documents
      src = @config[:source]
      out = []
      src.find do |f|
        Find.prune if f.basename.to_s[0] == ?.
        next if f.directory?
        out << f
      end

      out
    end

    def resolve_file path
      return unless path.file?
      path = Pathname('/') + path.relative_path_from(@config[:source])
      base = URI(@base.to_s)
      uri  = base + path.to_s

      #warn "trying #{uri}"

      until (out = canonical_uuid uri)
        # iteratively strip off
        break if uri.path.end_with? '/'

        dn = path.dirname
        bn = path.basename '.*'

        # try index first
        if bn.to_s == 'index'
          p = dn.to_s
          p << '/' unless p.end_with? '/'
          uri = base + p
        elsif bn == path.basename
          break
        else
          path = dn + bn
          uri = base + path.to_s
        end

        # warn "trying #{uri}"
      end

      out
    end

    # Determine whether the URI represents a published document.
    # 
    # @param uri
    # 
    # @return [true, false]
    def published? uri, circulated: false
      RDF::SAK::Util.published? @graph, uri,
        circulated: circulated, base: @base
    end

    # Find a destination pathname for the document
    #
    # @param uri
    # @param published
    # 
    # @return [Pathname]
    def target_for uri, published: false
      uri = coerce_resource uri
      uri = canonical_uuid uri
      target = @config[published?(uri) && published ? :target : :private]

      # target is a pathname so this makes a pathname
      target + "#{URI(uri.to_s).uuid}.xml"
    end

    # read from source

    # write (manipulated (x|x?ht)ml) back to source

    # write public and private variants to target

    def writex_html published: true
    end

    # write modified rdf

    # - internet stuff -

    # verify external links for upness

    # collect triples for external links

    # fetch references for people/companies/concepts/etc from dbpedia/wikidata

    # - document context class -

    class Document
      include XML::Mixup
      include Util

      private

      C_OK = [Nokogiri::XML::Node, IO, Pathname].freeze

      public

      attr_reader :doc, :uuid, :uri

      def initialize context, uuid, doc: nil, uri: nil, mtime: nil
        raise 'context must be a RDF::SAK::Context' unless
          context.is_a? RDF::SAK::Context
        raise 'uuid must be an RDF::URI' unless
          uuid.is_a? RDF::URI and uuid.to_s.start_with? 'urn:uuid:'

        doc ||= context.locate uuid
        raise 'doc must be Pathname, IO, or Nokogiri node' unless
          C_OK.any? { |c| doc.is_a? c } || doc.respond_to?(:to_s)

        # set some instance variables
        @context = context
        @uuid    = uuid
        @mtime   = mtime || doc.respond_to?(:mtime) ? doc.mtime : Time.now
        @target  = context.target_for uuid

        # now process the document

        # turn the document into an XML::Document
        if doc.is_a? Nokogiri::XML::Node
          # a node that is not a document should be wrapped with one
          unless doc.is_a? Nokogiri::XML::Document
            d = doc.dup 1
            doc = Nokogiri::XML::Document.new
            doc << d
          end
        else
          type = nil

          # pathnames turned into IO objects
          if doc.is_a? Pathname
            type = RDF::SAK::MimeMagic.by_path doc
            doc  = doc.open # this may raise if the file isn't there
          end

          # squash everything else to a string
          doc = doc.to_s unless doc.is_a? IO

          # check type by content
          type ||= RDF::SAK::MimeMagic.by_magic(doc)

          # can you believe there is a special bookmarks mime type good grief
          type = 'text/html' if type == 'application/x-mozilla-bookmarks'

          # now we try to parse the blob
          if type.to_s =~ /xml/i
            doc = Nokogiri.XML doc
          elsif type == 'text/html'
            # if the detected type is html, try it as strict xml first
            attempt = nil
            begin
              attempt = Nokogiri.XML doc, nil, nil, (1 << 11) # NONET
            rescue Nokogiri::XML::SyntaxError
              # do not wrap this a second time; let it fail if it's gonna
              tmp = Nokogiri.HTML doc
              attempt = Nokogiri::XML::Document.new
              attempt << tmp.root.dup(1)
            end
            doc = attempt
          elsif type.to_s =~ /^text\/(?:plain|(?:x-)?markdown)/i
            # just assume plain text is markdown
            doc = ::MD::Noko.new.ingest doc
          else
            raise "Don't know what to do with #{uuid} (#{type})"
          end
        end

        # now fix the namespaces for mangled html documents
        root = doc.root
        if root.name == 'html'
          unless root.namespace
            # clear this off or it will be duplicated in the output
            root.remove_attribute('xmlns')
            # now generate a new ns object
            ns = root.add_namespace(nil, XHTMLNS)
            # *now* scan the document and add the namespace declaration
            root.traverse do |node|
              if node.element? && node.namespace.nil?
                # downcasing the name may be cargo culting; need to check
                # node.name = node.name.downcase # yup it is
                node.namespace = ns
              end
            end
          end

          # also add the magic blank doctype declaration if it's missing
          unless doc.internal_subset
            doc.create_internal_subset('html', nil, nil)
          end
        end

        # aaand set some more instance variables

        @uri = URI(uri || @context.canonical_uri(uuid))

        # voilà
        @doc = doc
      end

      # proxy for context published
      def published?
        @context.published? @uuid
      end

      def base_for node = nil
        node ||= @doc
        doc  = node.document
        base = @uri.to_s
        if doc.root.name.to_sym == :html
          b = doc.at_xpath(
            '(/html:html/html:head/html:base[@href])[1]/@href',
            { html: XHTMLNS }).to_s.strip
          base = b if URI(b).absolute?
        elsif b = doc.at_xpath('ancestor-or-self::*[@xml:base][1]/@xml:base')
          b = b.to_s.strip
          base = b if URI(b).absolute?
        end

        URI(base)
      end

      # notice these are only RDFa attributes that take URIs
      RDFA_ATTR  = [:about, :resource, :typeof].freeze
      LINK_ATTR  = [:href, :src, :data, :action, :longdesc].freeze
      LINK_XPATH = ('.//html:*[not(self::html:base)][%s]' %
        (LINK_ATTR + RDFA_ATTR).map { |a| "@#{a.to_s}" }.join('|')).freeze

      def rewrite_links node = @doc, uuids: {}, uris: {}, &block
        base  = base_for node
        count = 0
        cache = {}
        node.xpath(LINK_XPATH, { html: XHTMLNS }).each do |elem|
          LINK_ATTR.each do |attr|
            attr = attr.to_s
            next unless elem.has_attribute? attr

            abs = base.merge uri_pp(elem[attr].strip)

            # fix e.g. http->https
            if abs.host == @uri.host and abs.scheme != @uri.scheme
              tmp          = @uri.dup
              tmp.path     = abs.path
              tmp.query    = abs.query
              tmp.fragment = abs.fragment
              abs          = tmp
            end

            # harvest query string
            pp = split_pp abs, only: true

            abs = RDF::URI(abs.to_s)

            # round-trip to uuid and back if we can
            if uuid = uuids[abs] ||= @context.canonical_uuid(abs)
              abs = cache[abs] ||= @context.canonical_uri(uuid)
            else
              abs = cache[abs] ||= @context.canonical_uri(abs)
            end

            # reinstate the path parameters
            if !pp.empty? && split_pp(abs, only: true).empty?
              abs = abs.dup
              abs.path = ([abs.path] + pp).join(';')
            end
            

            elem[attr] = @uri.route_to(abs.to_s).to_s
            count += 1
          end

          block.call elem if block
        end

        count
      end

      # sponge the document for rdfa
      def triples_for
      end

      OBJS = [:href, :src].freeze
      
      # ancestor node always with (@property and not @content) and
      # not @resource|@href|@src unless @rel|@rev
      LITXP = ['(ancestor::*[@property][not(@content)]',
        '[not(@resource|@href|@src) or @rel|@rev])[1]' ].join('').freeze
      # note parentheses cause the index to be counted from the root

      def vocab_for node
        if node[:vocab]
          vocab = node[:vocab].strip
          return nil if vocab == ''
          vocab = RDF::URI(vocab)
          return RDF::Vocabulary.find_term(vocab) rescue vocab
        end
        parent = node.parent
        vocab_for parent if parent and parent.element?
      end

      def prefixes_for node, prefixes = {}
        prefixes = prefixes.transform_keys(&:to_sym);

        # start with namespaces
        pfx = node.namespaces.select do |k, _|
          k.start_with? 'xmlns:'
        end.transform_keys do |k|
          k.delete_prefix('xmlns:').to_sym
        end

        # then add @prefix overtop of the namespaces
        if node[:prefix]
          x = node[:prefix].strip.split(/\s+/)
          a = []
          b = []
          x.each_index { |i| (i % 2 == 0 ? a : b).push x[i] }
          a.map!(&:to_sym)
          # if the size is uneven the values will be nil, so w drop em
          pfx.merge! a.zip(b).to_h.reject { |_, v| v.nil? }
        end

        # since we're ascending the tree, input takes precedence
        prefixes = pfx.transform_values do |v|
          v = RDF::URI(v)
          RDF::Vocabulary.find_term(v) rescue v
        end.merge prefixes
      
        if node.parent and node.parent.element?
          prefixes_for node.parent, prefixes
        else
          prefixes
        end
      end

      # backlink structure
      def generate_backlinks published: true, ignore: nil
        @context.generate_backlinks @uuid, published: published, ignore: ignore
      end

      # goofy twitter-specific metadata
      def generate_twitter_meta
        @context.generate_twitter_meta @uuid
      end

      def transform_xhtml published: true
        # before we do any more work make sure this is html
        doc  = @doc.dup 1
        body = doc.at_xpath('//html:body[1]', { html: XHTMLNS }) or return

        # eliminate comments
        doc.xpath('//comment()[not(ancestor::html:script)]',
          { html: XHTMLNS }).each { |c| c.unlink }

        # initial stuff
        struct    = @context.struct_for @uuid, uuids: true, canon: true
        # rstruct   = @context.struct_for @uuid, uuids: true, rev: true
        resources = {}
        literals  = {}
        ufwd      = {} # uuid -> uri
        urev      = {} # uri  -> uuid
        datatypes = Set.new
        types     = Set.new
        authors   = @context.authors_for(@uuid)
        title     = @context.label_for @uuid, candidates: struct
        desc      = @context.label_for @uuid, candidates: struct, desc: true

        # rewrite content
        title = title[1] if title
        desc  = desc[1]  if desc

        # `struct` and `rstruct` will contain all the links and
        # metadata for forward and backward neighbours, respectively,
        # which we need to mine (predicates, classes, datatypes) for
        # prefixes among other things.

        struct.each do |p, v|
          v.each do |o|
            if o.literal?
              literals[o] ||= Set.new
              literals[o].add p

              # collect the datatype
              datatypes.add o.datatype if o.has_datatype?
            else
              # normalize URIs
              if o.to_s.start_with? 'urn:uuid:'
                ufwd[o] ||= @context.canonical_uri o
              elsif cu = @context.canonical_uuid(o)
                o = urev[o] ||= cu
              end


              # collect the resource
              resources[o] ||= Set.new
              resources[o].add p

              # add to type
              types.add o if p == RDF::RDFV.type
            end
          end
        end
        urev.merge! ufwd.invert

        labels = resources.keys.map do |k|
          # turn this into a pair which subsequently gets turned into a hash
          [k, @context.label_for(k) ]
        end.to_h

        #warn labels

        # handle the title
        title ||= RDF::Literal('')
        tm = { '#title' => title,
          property: @context.abbreviate(literals[title].to_a, vocab: XHV) }
        if tl = title.language
          tm['xml:lang'] = tl # if xmlns
          tm['lang'] = tl
        elsif tdt = title.datatype and tdt != RDF::XSD.string
          tm[:datatype] = @context.abbreviate(tdt)
        end

        # we accumulate a record of the links in the body so we know
        # which ones to skip in the head
        bodylinks = {}
        rewrite_links body, uuids: ufwd, uris: urev do |elem|
          vocab = elem.at_xpath('ancestor-or-self::*[@vocab][1]/@vocab')
          vocab = uri_pp(vocab.to_s) if vocab

          if elem.key?('href') or elem.key?('src')
            vu = uri_pp(elem['href'] || elem['src'])
            ru = RDF::URI(@uri.merge(vu))
            bodylinks[urev[ru] || ru] = true

            if rel = resources[urev[ru] || ru]
              elem['rel'] = (@context.abbreviate rel, vocab: vocab).join ' '
            end

            label = labels[urev[ru] || ru]
            if label and (!elem.key?('title') or elem['title'].strip == '')
              elem['title'] = label[1].to_s
            end
          end
        end

        # and now we do the head
        links = @context.head_links @uuid, struct: struct, nodes: resources,
          prefixes: @context.prefixes, ignore: bodylinks.keys, labels: labels,
          vocab: XHV, rev: RDF::SAK::CI.document

        # we want to duplicate links from particular subjects (eg the root)
        (@context.config[:duplicate] || {}).sort do |a, b|
          a.first <=> b.first
        end.each do |s, preds|

          o = {}
          u = ufwd[s] ||= @context.canonical_uuid s
          s = urev[u] ||= @context.canonical_uri u if u
          f = {}

          # do not include this subject as these links are already included!
          next if u == @uuid

          # gather up the objects, then gather up the predicates

          @context.objects_for u || s, preds, only: :resource do |obj, rel|
            # XXX do not know why += |= etc does not work
            x = @context.canonical_uuid(obj) || obj
            urev[x] ||= @context.canonical_uri x
            y = o[x] ||= Set.new
            o[x] = y | rel
            f[x] = @context.formats_for x
          end

          srel = @uri.route_to((u ? urev[u] || s : s).to_s)

          # now collect all the other predicates
          o.keys.each do |obj|
            hrel = @uri.route_to((urev[obj] || obj).to_s)
            o[obj] |= @context.graph.query([u || s, nil, obj]).predicates.to_set
            rels = @context.abbreviate o[obj].to_a, vocab: XHV
            ln = { nil => :link, about: srel, rel: rels, href: hrel }
            ln[:type] = f[obj].first if f[obj]

            # add to links
            links << ln
          end
        end

        meta = []

        # include author names as old school meta tags
        authors.each do |a|
          name  = labels[urev[a] || a] or next
          datatypes.add name[0] # a convenient place to chuck this
          prop  = @context.abbreviate(name[0])
          name  = name[1]
          about = @uri.route_to((ufwd[a] || a).to_s)
          tag   = { nil => :meta, about: about.to_s, name: :author,
                   property: prop, content: name.to_s }

          if name.has_datatype? and name.datatype != RDF::XSD.string
            tag[:datatype] = @context.abbreviate(name.datatype)
          elsif name.has_language?
            tag['xml:lang'] = tag[:lang] = name.language
          end
          meta.push tag
        end

        literals.each do |k, v|
          next if k == title
          rel = @context.abbreviate v.to_a, vocab: XHV
          elem = { nil => :meta, property: rel, content: k.to_s }
          elem[:name] = :description if k == desc

          if k.has_datatype?
            datatypes.add k.datatype # so we get the prefix
            elem[:datatype] = @context.abbreviate k.datatype, vocab: XHV
          end

          meta.push(elem)
        end

        meta.sort! do |a, b|
          s = 0
          [:about, :property, :datatype, :content, :name].each do |k|
            # warn a.inspect, b.inspect
            s = a.fetch(k, '').to_s <=> b.fetch(k, '').to_s
            break if s != 0
          end
          s
        end

        # don't forget style tag
        style = doc.xpath('/html:html/html:head/html:style', { html: XHTMLNS })

        body = body.dup 1
        body = { '#body' => body.children.to_a, about: '' }
        body[:typeof] = @context.abbreviate(types.to_a, vocab: XHV) unless
          types.empty?

        # prepare only the prefixes we need to resolve the data we need
        rsc = @context.abbreviate(
          (struct.keys + resources.keys + datatypes.to_a + types.to_a).uniq,
          noop: false).map do |x|
          next if x.nil?
          x.split(?:)[0].to_sym
        end.select { |x| not x.nil? }.to_set

        pfx = @context.prefixes.select do |k, _|
          rsc.include? k
        end.transform_values { |v| v.to_s }

        # XXX deal with the qb:Observation separately (just nuke it for now)
        extra = generate_twitter_meta || []
        if bl = generate_backlinks(published: published)#,
          # ignore: @context.graph.query(
          # [nil, CI.document, @uuid]).subjects.to_set)
          extra << { [bl] => :object }
        end

        # and now for the document
        xf  = @context.config[:transform]
        doc = xhtml_stub(
          base: @uri, prefix: pfx, vocab: XHV, lang: 'en', title: tm,
          link: links, meta: meta, style: style, transform: xf,
          extra: extra, body: body).document

        # goddamn script tags and text/html
        doc.xpath('//html:script[@src][not(node())]',
          { html: XHTMLNS }).each do |script|
          script << doc.create_text_node('')
        end

        doc
      end

      # Actually write the transformed document to the target
      #
      # @param published [true, false] 
      #
      # @return [Array] pathname(s) written
      def write_to_target published: true

        # in all cases we write to private target
        states = [false]
        # document has to be publishable
        states.push true if published && @context.published?(@uuid)

        ok = []
        states.each do |state|
          target = @context.config[state ? :target : :private]

          # XXX this is dumb; it should do something more robust if it
          # fails
          doc = transform_xhtml(published: state) or next

          begin
            fh   = Tempfile.create('xml-', target)
            path = Pathname(fh.path)

            # write the doc to the target
            doc.write_to fh
            fh.close

            uuid = URI(@uuid.to_s)
            newpath = path.dirname + "#{uuid.uuid}.xml"
            ok.push newpath

            File.chmod(0644, path)
            File.rename(path, newpath)
            File.utime(@mtime, @mtime, newpath)
          rescue Exception => e
            # XXX this should only rescue a specific class of errors
            warn e.class, e
            File.unlink path if path.exist?
          end
        end

        ok
      end

    end
  end
end
