# -*- coding: utf-8 -*-
require 'rdf/sak/version'

# basic stuff
require 'stringio'
require 'pathname'
require 'mimemagic'

# rdf stuff
require 'uri'
require 'uri/urn'
require 'rdf'
require 'rdf/reasoner'
require 'linkeddata'

# cli stuff
require 'commander'

# my stuff
require 'xml-mixup'
require 'md-noko'
require 'uuid-ncname'

# ontologies, mine in particular
require 'rdf/sak/ci'
require 'rdf/sak/ibis'
# others not included in rdf.rb
require 'rdf/sak/pav'

module RDF::SAK

  # janky bolt-on MimeMagic
  class MimeMagic < ::MimeMagic

    # XXX this is not strictly correct but good enough for now
    [
      ['text/n3', %w(n3 ttl nt), %w(text/plain), [[0..256, '@prefix']]],
    ].each do |magic|
      self.add magic[0], extensions: magic[1], parents: magic[2],
        magic: magic[3]
    end

    def self.binary? thing
      sample = nil

      # get some stuff out of the IO or get a substring
      if thing.is_a? IO
        pos = thing.tell
        thing.seek 0, 0
        sample = thing.read 100
        thing.seek pos
      else
        sample = thing.to_s[0,100]
      end

      # consider this to be 'binary' if empty
      return true if sample.length == 0
      # control codes minus ordinary whitespace
      sample.b =~ /[\x0-\x8\xe-\x1f\x7f]/ ? true : false
    end

    def self.default_type thing
      new(self.binary?(thing) ? 'application/octet-stream' : 'text/plain')
    end

    def self.by_extension io
      super(io) || default_type(io)
    end

    def self.by_path io
      super(io) || default_type(io)
    end

    def self.by_magic io
      super(io) || default_type(io)
    end

    def self.all_by_magic io
      out = super(io)
      out.length > 0 ? out : [default_type(io)]
    end

  end

  class Context
    include XML::Mixup

    private

    RDF::Reasoner.apply(:rdfs, :owl)

    # okay labels: what do we want to do about them? poor man's fresnel!

    # basic structure is an asserted base class corresponding to a
    # ranked list of asserted predicates. to the subject we first
    # match the closest class, then the closest property.

    # if the instance data doesn't have an exact property mentioned in
    # the spec, it may have an equivalent property or subproperty we
    # may be able to use. we could imagine a scoring system analogous
    # to the one used by CSS selectors, albeit using the topological
    # distance of classes/predicates in the spec versus those in the
    # instance data.

    # think about dcterms:title is a subproperty of dc11:title even
    # though they are actually more like equivalent properties;
    # owl:equivalentProperty is not as big a conundrum as
    # rdfs:subPropertyOf. 

    # if Q rdfs:subPropertyOf P then S Q O implies S P O. this is
    # great but property Q may not be desirable to display.

    # it may be desirable to be able to express properties to never
    # use as a label, such as skos:hiddenLabel

    # consider ranked alternates, sequences, sequences of alternates.
    # (this is what fresnel does fyi)

    STRINGS = {
      RDF::RDFS.Resource => {
        label: [
          # main
          [RDF::Vocab::SKOS.prefLabel, RDF::RDFS.label,
            RDF::Vocab::DC.title, RDF::Vocab::DC11.title],
          # alt
          [RDF::Vocab::SKOS.altLabel, RDF::Vocab::DC.alternative],
        ],
        desc: [
          # main will be cloned into alt
          [RDF::Vocab::DC.description, RDF::Vocab::DC11.description,
            RDF::RDFS.comment, RDF::Vocab::SKOS.note],
        ],
      },
      RDF::Vocab::FOAF.Document => {
        label: [
          # main
          [RDF::Vocab::DC.title, RDF::Vocab::DC11.title],
          # alt
          [RDF::Vocab::BIBO.shortTitle, RDF::Vocab::DC.alternative],
        ],
        desc: [
          # main
          [RDF::Vocab::BIBO.abstract, RDF::Vocab::DC.abstract,
            RDF::Vocab::DC.description, RDF::Vocab::DC11.description],
          # alt
          [RDF::Vocab::BIBO.shortDescription],
        ],
      },
      RDF::Vocab::FOAF.Agent => {
        label: [
          # main (will get cloned into alt)
          [RDF::Vocab::FOAF.name],
        ],
        desc: [
          # main cloned into alt
          [RDF::Vocab::FOAF.status],
        ],
      },
    }
    STRINGS[RDF::OWL.Thing] = STRINGS[RDF::RDFS.Resource]

    # note this is to_a because "can't modify a hash during iteration"
    # which i guess is sensible, so we generate a set of pairs first
    STRINGS.to_a.each do |type, struct|
      struct.values.each do |lst|
        # assert a whole bunch of stuff
        raise 'STRINGS content must be an array of arrays' unless
          lst.is_a? Array
        raise 'Spec must contain 1 or 2 Array elements' if lst.empty?
        raise 'Spec must be array of arrays of terms' unless
          lst.all? { |x| x.is_a? Array and x.all? { |y|
            RDF::Vocabulary.find_term(y) } }

        # prune this to two elements (not that there should be more than)
        lst.slice!(2, lst.length) if lst.length > 2

        # pre-fill equivalent properties
        lst.each do |preds|
          # for each predicate, find its equivalent properties

          # splice them in after the current predicate only if they
          # are not already explicitly in the list
          i = 0
          loop do
            equiv = preds[i].entail(:equivalentProperty) - preds
            preds.insert(i + 1, *equiv) unless equiv.empty?

            i += equiv.length + 1
            break if i >= preds.length
          end

          # this just causes too many problems otherwise
          # preds.map! { |p| p.to_s }
        end

        # duplicate main predicates to alternatives
        lst[1] ||= lst[0]
      end

      # may as well seed equivalent classes so we don't have to look them up
      type.entail(:equivalentClass).each do |equiv|
        STRINGS[equiv] ||= struct
      end

      # tempting to do subclasses too but it seems pretty costly in
      # this framework; save it for the clojure version
    end

    G_OK = [RDF::Repository, RDF::Dataset, RDF::Graph].freeze
    C_OK = [Pathname, IO, String].freeze

    def coerce_graph graph = nil, type: nil
      return RDF::Repository.new unless graph
      return graph if G_OK.any? { |c| graph.is_a? c }
      raise 'Graph must be some kind of RDF::Graph or RDF data file' unless
        C_OK.any? { |c| graph.is_a? c } || graph.respond_to?(:to_s)

      opts = {}
      opts[:content_type] = type if type

      if graph.is_a? Pathname
        opts[:filename] = graph.expand_path.to_s
        graph = graph.open
      elsif graph.is_a? File
        opts[:filename] = graph.path
      end

      graph = StringIO.new(graph.to_s) unless graph.is_a? IO
      reader = RDF::Reader.for(opts) do
        graph.rewind
        sample = graph.read 1000
        graph.rewind
        sample
      end or raise "Could not find an RDF::Reader for #{opts[:content_type]}"

      out = RDF::Repository.new

      reader = reader.new graph, **opts
      reader.each_statement do |stmt|
        out << stmt
      end

      out
    end

    SCHEME_RANK = { https: 0, http: 1 }

    def cmp_resource a, b, www: nil
      raise 'Comparands must be instances of RDF::Value' unless
        [a, b].all? { |x| x.is_a? RDF::Value }

      # URI beats non-URI
      if a.uri?
        if b.uri?
          # https beats http beats other
          as = a.scheme.downcase.to_sym
          bs = b.scheme.downcase.to_sym
          cmp = SCHEME_RANK.fetch(as, 2) <=> SCHEME_RANK.fetch(bs, 2)

          # bail out early
          return cmp unless cmp == 0

          # this would have returned if the schemes were different, as
          # such we only need to test one of them
          if [:http, :https].any?(as) and not www.nil?
            # if www is non-nil, prefer www or no-www depending on
            # truthiness of `www` parameter
            pref = [false, true].zip(www ? [1, 0] : [0, 1]).to_h
            re = /^(?:(www)\.)?(.*?)$/

            ah = re.match(a.host.to_s.downcase)[1,2]
            bh = re.match(b.host.to_s.downcase)[1,2]

            # compare hosts sans www
            cmp = ah[1] <=> bh[1]
            return cmp unless cmp == 0

            # now compare presence of www
            cmp = pref[ah[0] == 'www'] <=> pref[bh[0] == 'www']
            return cmp unless cmp == 0

            # if we're still here, compare the path/query/fragment
            re = /^.*?\/\/.*?(\/.*)$/
            al = re.match(a.to_s)[1].to_s
            bl = re.match(b.to_s)[1].to_s

            return al <=> bl
          end

          return a <=> b
        else
          return -1
        end
      elsif b.uri?
        return 1
      else
        return a <=> b
      end
    end
    
    # rdf term type tests
    NTESTS = { uri: :"uri?", blank: :"node?", literal: :"literal?" }.freeze
    NMAP   = ({ iri: :uri, bnode: :blank }.merge(
      [:uri, :blank, :literal].map { |x| [x, x] }.to_h)).freeze

    def coerce_node_spec spec
      spec = [spec] unless spec.respond_to? :to_a
      spec = spec - [:resource] + [:uri, :blank] if spec.include? :resource
      spec = NMAP.values_at(*spec).reject(&:nil?).uniq
      spec = NTESTS.keys if spec.length == 0
      spec
    end

    def node_matches? node, spec
      spec.any? { |k| node.send NTESTS[k] }
    end

    AUTHOR  = [RDF::SAK::PAV.authoredBy, RDF::Vocab::DC.creator,
      RDF::Vocab::DC11.creator, RDF::Vocab::PROV.wasAttributedTo]
    CONTRIB = [RDF::SAK::PAV.contributedBy, RDF::Vocab::DC.contributor,
      RDF::Vocab::DC11.contributor]
    [AUTHOR, CONTRIB].each do |preds|
      i = 0
      loop do
        equiv = preds[i].entail(:equivalentProperty) - preds
        preds.insert(i + 1, *equiv) unless equiv.empty?
        i += equiv.length + 1
        break if i >= preds.length
      end

      preds.freeze
    end

    def term_list terms
      terms = terms.respond_to?(:to_a) ? terms.to_a : [terms]
      terms.uniq.map { |t| RDF::Vocabulary.find_term }.compact
    end

    public

    attr_reader :graph

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

      @graph = coerce_graph graph, type: type
      @base  = RDF::URI.new base.to_s if base
    end

    # Obtain a key-value structure for the given subject, optionally
    # constraining the result by node type (:resource, :uri/:iri,
    # :blank/:bnode, :literal)
    #
    # @param subject
    # @param only
    #
    # @return [Hash]

    def struct_for subject, only: []
      only = coerce_node_spec only

      rsrc = {}
      @graph.query([subject, nil, nil]).each do |stmt|
        # this will skip over any term not matching the type
        next unless node_matches? stmt.object, only
        p = RDF::Vocabulary.find_term(stmt.predicate) || stmt.predicate
        o = rsrc[p] ||= []
        o.push stmt.object
      end

      # XXX in here we can do fun stuff like filter/sort by language/datatype
      rsrc.each do |k, v|
        v.sort!
      end

      rsrc
    end

    # Obtain everything in the graph that is an `rdf:type` of something.
    # 
    # @return [Array]

    def all_types
      @graph.query([nil, RDF.type, nil]).collect do |s|
        s.object
      end.uniq
    end

    # Obtain every subject that is rdf:type the given type or its subtypes.
    #
    # @param rdftype [RDF::Term]
    #
    # @return [Array]

    def all_of_type rdftype
      t = RDF::Vocabulary.find_term(rdftype) or raise "No type #{rdftype.to_s}"
      out = []
      (all_types & all_related(t)).each do |type|
        out += @graph.query([nil, RDF.type, type]).collect { |s| s.subject }
      end
      
      out.uniq
    end

    # Obtain everything that is an owl:equivalentClass or
    # rdfs:subClassOf the given type.
    #
    # @param rdftype [RDF::Term]
    #
    # @return [Array]

    def all_related rdftype
      t = RDF::Vocabulary.find_term(rdftype) or raise "No type #{rdftype.to_s}"
      q = [t] # queue
      c = {}  # cache

      while term = q.shift
        # add term to cache
        c[term] = term
        # entail equivalent classes
        term.entail(:equivalentClass).each do |ec|
          # add equivalent classes to queue (if not already cached)
          q.push ec unless c[ec]
          c[ec] = ec unless ec == term
        end
        # entail subclasses
        term.subClass.each do |sc|
          # add subclasses to queue (if not already cached)
          q.push sc unless c[sc]
          c[sc] = sc unless sc == term
        end
      end

      # smush the result 
      c.keys
    end

    # Obtain a stack of types for an asserted initial type or set
    # thereof. Returns an array of arrays, where the first is the
    # asserted types and their inferred equivalents, and subsequent
    # elements are immediate superclasses and their equivalents. A
    # given URI will only appear once in the entire structure.
    #
    # @param rdftype [RDF::Term, :to_a]
    #
    # @return [Array]

    def type_strata rdftype
      # first we coerce this to an array
      if rdftype.respond_to? :to_a
        rdftype = rdftype.to_a
      else
        rdftype = [rdftype]
      end
      
      # now squash and coerce
      rdftype = rdftype.uniq.map { |t| RDF::Vocabulary.find_term t }.compact

      # bail out early
      return [] if rdftype.count == 0

      # essentially what we want to do is construct a layer of
      # asserted classes and their inferred equivalents, then probe
      # the classes in the first layer for subClassOf assertions,
      # which will form the second layer, and so on.

      queue  = [rdftype]
      strata = []
      seen   = Set.new

      while qin = queue.shift
        qwork = []

        qin.each do |q|
          qwork << q # entail doesn't include q
          qwork += q.entail(:equivalentClass)
        end

        # grep and flatten
        qwork = qwork.map { |t| RDF::Vocabulary.find_term t }.compact.uniq
        qwork -= seen.to_a
        seen |= qwork

        # push current layer out
        strata.push qwork if qwork.length > 0
     
        # now deal with subClassOf
        qsuper = []
        qwork.each { |q| qsuper += q.subClassOf }

        # grep and flatten this too
        qsuper = qsuper.map { |t| RDF::Vocabulary.find_term t }.compact.uniq
        qsuper -= seen.to_a
        seen |= qsuper

        # same deal, conditionally push the input queue
        queue.push qsuper if qsuper.length > 0
      end

      # voila
      strata
    end

    # Obtain all and only the rdf:types directly asserted on the subject.
    # 
    # @param subject [RDF::Resource]
    # @param type [RDF::Term, :to_a]
    #
    # @return [Array]

    def asserted_types subject, type = nil
      asserted = nil
      if type
        type = type.respond_to?(:to_a) ? type.to_a : [type]
        asserted = type.select { |t| t.is_a? RDF::Value }.map do |t|
          RDF::Vocabulary.find_term t
        end
      end
      asserted ||= @graph.query([subject, RDF.type, nil]).collect do |st|
        RDF::Vocabulary.find_term st.object
      end
      asserted.select { |t| t && t.uri? }.uniq
    end

    # Obtain the "best" dereferenceable URI for the subject.
    # Optionally returns all candidates.
    # 
    # @param subject [RDF::Resource]
    # @param unique [true, false]
    #
    # @return [RDF::URI, Array]

    def canonical_uri subject, unique: true
      out = []

      [CI.canonical, RDF::OWL.sameAs].each do |p|
        o = @graph.query([subject, p, nil]).collect { |st| st.object }
        out += o.sort { |a, b| cmp_resource(a, b) }
      end

      # try to generate 
      if out.empty? and subject.uri?
        uri = URI.parse subject.to_s
        if @base and uri.respond_to? :uuid
          b = @base.clone
          b.query = b.fragment = nil
          b.path = '/' + uri.uuid
          out << RDF::URI.new(b.to_s)
        end
      end

      unique ? out.first : out.uniq
    end

    # Obtain the objects for a given subject-predicate pair.
    #
    # @param subject [RDF::Resource]
    # @param predicate [RDF::URI]
    # @param entail [false, true]
    # @param only [:uri, :iri, :resource, :blank, :bnode, :literal]
    # @param datatype [RDF::Term]
    #
    # @return [Array]

    def objects_for subject, predicate, entail: true, only: [], datatype: nil
      raise 'Subject must be a resource' unless subject.is_a? RDF::Resource
      predicate = predicate.respond_to?(:to_a) ? predicate.to_a : [predicate]
      raise 'Predicate must be some kind of term' unless
        predicate.all? { |p| p.is_a? RDF::URI }

      predicate = predicate.map { |x| RDF::Vocabulary.find_term x }.compact

      only = coerce_node_spec only

      datatype = (
        datatype.respond_to?(:to_a) ? datatype.to_a : [datatype]).compact
      raise 'Datatype must be some kind of term' unless
        datatype.all? { |p| p.is_a? RDF::URI }

      # XXX we really should wrap this up huh
      if entail
        i = 0
        loop do
          equiv = predicate[i].entail(:equivalentProperty) - predicate
          predicate.insert(i + 1, *equiv) unless equiv.empty?
          i += equiv.length + 1
          break if i >= predicate.length
        end
      end

      out = []
      predicate.each do |p|
        @graph.query([subject, p, nil]).each do |stmt|
          o = stmt.object

          # warn o

          # make sure it's in the spec
          next unless node_matches? o, only

          # constrain output
          next if o.literal? and
            !(datatype.empty? or datatype.include?(o.datatype))

          out.push o
        end
      end

      out.uniq
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

    def authors_for subject, unique: false, contrib: false
      authors = []

      # try the author list
      lp = [RDF::Vocab::BIBO[contrib ? :contributorList : :authorList]]
      lp += lp[0].entail(:equivalentProperty) # XXX cache this
      lp.each do |pred|
        o = @graph.first_object([subject, pred, nil])
        next unless o
        # note this use of RDF::List is not particularly well-documented
        authors += RDF::List.new(subject: o, graph: @graph).to_a
      end

      # now try various permutations of the author/contributor predicate
      unsorted = []
      preds = contrib ? CONTRIB : AUTHOR
      preds.each do |pred|
        unsorted += @graph.query([subject, pred, nil]).collect { |x| x.object }
      end

      authors += unsorted.uniq.sort { |a, b| label_for(a) <=> label_for(b) }

      unique ? authors.first : authors.uniq
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

    def label_for subject, unique: true, type: nil,
        lang: nil, desc: false, alt: false
      return unless subject and subject.is_a? RDF::Value and subject.resource?
      # get type(s) if not supplied
      asserted = asserted_types subject, type

      # get all the inferred types by layer; add default class if needed
      strata = type_strata asserted
      strata.push [RDF::RDFS.Resource] if
        strata.length == 0 or not strata[-1].include?(RDF::RDFS.Resource)

      # get the key-value pairs for the subject
      candidates = struct_for subject, only: :literal

      seen  = {}
      accum = []
      strata.each do |lst|
        lst.each do |cls|
          next unless STRINGS[cls] and
            preds = STRINGS[cls][desc ? :desc : :label][alt ? 1 : 0]
          # warn cls
          preds.each do |p|
            # warn p.inspect
            next unless vals = candidates[p]
            vals.each do |v|
              pair = [p, v]
              accum.push(pair) unless seen[pair]
              seen[pair] = true
            end
          end
        end
      end

      # try that for now
      accum[0]

      # what we want to do is match the predicates from the subject to
      # the predicates in the label designation

      # get label predicate stack(s) for RDF type(s)

      # get all predicates in order (use alt stack if doubly specified)

      # filter out desired language(s)

      # XXX note we will probably want to return the predicate as well
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

    # segmentation of composite documents into multiple files

    # aggregation of simple documents into composites

    # generate backlinks

    # - resource (ie file) generation -

    # generate indexes of people, groups, and organizations

    # generate indexes of books, not-books, and other external links

    # generate skos concept schemes

    # generate atom feed

    #

    def generate_atom_feed id, published: true
      raise 'ID must be a resource' unless id.is_a? RDF::Resource

      feed = struct_for id

      # find all UUIDs that are documents
      docs = all_of_type(RDF::Vocab::FOAF.Document).select do |x|
        x =~ /^urn:uuid:/
      end

      # prune out all but the published documents if specified
      if published
        p = RDF::Vocab::BIBO.status
        o = RDF::Vocabulary.find_term(
          'http://purl.org/ontology/bibo/status/published')
        docs = docs.select do |s|
          @graph.has_statement? RDF::Statement(s, p, o)
        end
      end

      # now we create a hash keyed by uuid containing the metadata
      authors = {}
      dates   = {}
      entries = {}
      docs.each do |uu|
        # basically make a jsonld-like structure
        #rsrc = struct_for uu

        # get id (got it already duh)
        
        # get canonical link
        # canon = ((rsrc[CI.canonical] || []) +
        #   (rsrc[RDF::OWL.sameAs] || [])).find(-> { uu }) { |x| x.resource? }
        # canon = URI.parse canon.to_s

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
        dates[uu] = updated = Time.parse(updated.to_s).utc

        xml['#entry'].push({ '#updated' => updated.iso8601 })
        if published
          published = Time.parse(published.to_s).utc
          xml['#entry'].push({ '#published' => published.iso8601 })
          dates[uu] = published
        end

        # get author(s)
        al = []
        authors_for(uu).each do |a|
          unless authors[a]
            n = label_for a
            x = authors[a] = { '#author' => [{ '#name' => n[1].to_s }] }

            hp = @graph.first_object [a, RDF::Vocab::FOAF.homepage, nil]
            hp ||= canonical_uri a
            
            x['#author'].push({ '#uri' => hp.to_s }) if hp
          end

          al.push authors[a]
        end

        xml['#entry'] += al unless al.empty?

        # get title (note unshift)
        if (t = label_for uu)
          xml['#entry'].unshift({ '#title' => t[1].to_s })
        end
        
        # get abstract
        if (d = label_for uu, desc: true)
          xml['#entry'].push({ '#summary' => d[1].to_s })
        end
        
        entries[uu] = xml
      end

      # note we overwrite the entries hash here with a sorted array
      entries = entries.values_at(
        *entries.keys.sort { |a, b| dates[a] <=> dates[b] })
      # ugggh god forgot the asterisk and lost an hour

      # now we punt out the file

      preamble = [
        # { '#title' =>
        # { id = id.to_s },
        
      ]

      markup(spec: { '#feed' => preamble + entries,
        xmlns: 'http://www.w3.org/2005/Atom' }).document
    end

    # generate sass palettes

    # generate rewrite map(s)

    def generate_rewrite_maps published: true
      # slug to uuid (internal)
      # uuid/slug to canonical slug (308)
      # retired slugs/uuids (410)
    end

    # - io stuff -

    # read from source

    # write (manipulated (x|x?ht)ml) back to source

    # write public and private variants to target

    def write_xhtml published: true
    end

    # write modified rdf

    # - internet stuff -

    # verify external links for upness

    # collect triples for external links

    # fetch references for people/companies/concepts/etc from dbpedia/wikidata

    # - document context class -

    class Document
      private

      C_OK = [Nokogiri::XML::Node, IO, Pathname].freeze

      public

      attr_reader :doc

      def initialize context, doc
        raise 'context must be a RDF::SAK::Context' unless
          context.is_a? RDF::SAK::Context
        raise 'doc must be Pathname, IO, or Nokogiri node' unless
          C_OK.any? { |c| doc.is_a? c } || doc.respond_to?(:to_s)

        @context = context

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
          if type =~ /xml/i
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
          elsif type =~ /^text\/(?:plain|(?:x-)?markdown)/i
            # just assume plain text is markdown
            doc = ::MD::Noko.new.ingest doc
          else
            raise "Don't know what to do with #{type}"
          end
        end

        # now fix the namespaces for mangled html documents
        root = doc.root
        if root.name == 'html'
          unless root.namespace
            # clear this off or it will be duplicated in the output
            root.remove_attribute('xmlns')
            # now generate a new ns object
            ns = root.add_namespace(nil, 'http://www.w3.org/1999/xhtml')
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

        # voilà
        @doc = doc
      end


    end

  end

  class CLI
    # This is a command-line interface

    include XML::Mixup
    include Commander::Methods

    # bunch of data declarations etc we don't want to expose
    private

    # actual methods
    public

    # constructor

    def initialize
    end

    # vestigial

    def run
      run!
    end
  end
end
