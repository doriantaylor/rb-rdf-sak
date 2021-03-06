# -*- coding: utf-8 -*-
require 'rdf/sak/version'

require 'uri'
require 'uri/urn'
require 'set'
require 'uuid-ncname'

require 'rdf'
require 'rdf/vocab'
require 'rdf/reasoner'
require 'rdf/vocab/skos'
require 'rdf/vocab/foaf'
require 'rdf/vocab/bibo'
require 'rdf/vocab/dc'
require 'rdf/vocab/dc11'

require 'rdf/sak/mimemagic'
require 'rdf/sak/ci'
require 'rdf/sak/tfo'
require 'rdf/sak/ibis'
require 'rdf/sak/pav'
require 'rdf/sak/qb'

unless RDF::List.respond_to? :from
  class RDF::List
    private

    def self.get_list repo, subject, seen = []
      out = []
      return out if seen.include? subject
      seen << subject
      first = repo.query([subject, RDF.first, nil]).objects.first or return out
      out << first
      rest  = repo.query([subject, RDF.rest,  nil]).objects.select do |x|
        !x.literal?
      end.first or return out

      out + (rest != RDF.nil ? get_list(repo, rest, seen) : [])
    end

    public

    # Inflate a list from a graph but don't change the graph
    def self.from graph, subject
      self.new graph: graph, subject: subject, values: get_list(graph, subject)
    end
  end
end

module RDF::SAK::Util
  
  private

  RDF::Reasoner.apply(:rdfs, :owl)

  R3986   = /^(([^:\/?#]+):)?(\/\/([^\/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?$/
  SF      = /[^[:alpha:][:digit:]\/\?%@!$&'()*+,:;=._~-]/n
  RFC3986 =
    /^(?:([^:\/?#]+):)?(?:\/\/([^\/?#]*))?([^?#]+)?(?:\?([^#]*))?(?:#(.*))?$/
  SEPS = [['', ?:], ['//', ''], ['', ''], [??, ''], [?#, '']].freeze

  XPATH = {
    htmlbase: proc {
      x = ['ancestor-or-self::html:html[1]/' \
        'html:head[html:base[@href]][1]/html:base[@href][1]/@href']
      (x << x.first.gsub('html:', '')).join ?| }.call,
    xmlbase: 'ancestor-or-self::*[@xml:base][1]/@xml:base',
    lang: 'normalize-space((%s)[last()])' %
      %w[lang xml:lang].map do |a|
      'ancestor-or-self::*[@%s][1]/@%s' % [a,a]
    end.join(?|),
    literal: '(ancestor::*[@property][not(@content)]' \
      '[not(@resource|@href|@src) or @rel|@rev])[1]',
    leaves: 'descendant::html:section[not(descendant::html:section)]' \
      '[not(*[not(self::html:script)])]',
    headers: './*[1][%s]//text()' %
      (1..6).map { |x| "self::html:h#{x}" }.join(?|),
    modernize: ([
      "//html:div[*[1][#{(1..6).map { |i| 'self::html:h%d' % i }.join ?|}]]"] +
        { div: %i[section figure], blockquote: :note,
         table: :figure, img: :figure }.map do |k, v|
        (v.is_a?(Array) ? v : [v]).map do |cl|
          "//html:#{k}[contains(concat(' ', " \
            "normalize-space(@class), ' '), ' #{cl} ')]"
        end
      end.flatten).join(?|),
    dehydrate: '//html:a[count(*)=1][html:dfn|html:abbr|html:span]',
    rehydrate: %w[.//html:dfn
      .//html:abbr[not(parent::html:dfn)] .//html:span].join(?|) +
      '[not(parent::html:a)]',
    htmllinks: (%w[*[not(self::html:base)][@href]/@href
      *[@src]/@src object[@data]/@data *[@srcset]/@srcset
      form[@action]/@action].map { |e|
        '//html:%s' % e} + %w[//*[@xlink:href]/@xlink:href]).join(?|).freeze,
    atomlinks: %w[uri content/@src category/@scheme generator/@uri icon id
      link/@href logo].map { |e| '//atom:%s' % e }.join(?|).freeze,
    rsslinks: %w[image/text()[1] docs/text()[1] source/@url enclosure/@url
               guid/text()[1] comments/text()[1]].map { |e|
      '//%s' % e }.join(?|).freeze,
    xlinks: '//*[@xlink:href]/@xlink:href'.freeze,
    rdflinks: %w[about resource datatype].map { |e|
      '//*[@rdf:%s]/@rdf:%s' % [e, e] }.join(?|).freeze,
  }

  LINK_MAP = {
    'text/html'             => :htmllinks,
    'application/xhtml+xml' => :htmllinks,
    'application/atom+xml'  => :atomlinks,
    'application/x-rss+xml' => :rsslinks,
    'application/rdf+xml'   => :rdflinks,
    'image/svg+xml'         => :xlinks,
  }.transform_values { |v| XPATH[v] }.freeze

  URI_COERCIONS = {
    nil   => -> t { t.to_s },
    false => -> t { t.to_s },
    uri:     -> t { URI.parse t.to_s },
    rdf:     -> t {
      t = t.to_s
      t.start_with?('_:') ? RDF::Node.new(t.delete_prefix '_:') : RDF::URI(t) },
  }

  UUID_RE = /^(?:urn:uuid:)?([0-9a-f]{8}(?:-[0-9a-f]{4}){4}[0-9a-f]{8})$/i

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
          RDF::Vocab::DC.title, RDF::Vocab::DC11.title, RDF::RDFV.value],
        # alt
        [RDF::Vocab::SKOS.altLabel, RDF::Vocab::DC.alternative],
      ],
      desc: [
        # main will be cloned into alt
        [RDF::Vocab::DC.abstract, RDF::Vocab::DC.description,
          RDF::Vocab::DC11.description, RDF::RDFS.comment,
          RDF::Vocab::SKOS.note],
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

  def sanitize_prefixes prefixes, nonnil = false
    raise ArgumentError, 'prefixes must be a hash' unless
      prefixes.is_a? Hash or prefixes.respond_to? :to_h
    prefixes = prefixes.to_h.map do |k, v|
      [k ? k.to_s.to_sym : nil, v ? v.to_s : nil]
    end.to_h

    prefixes.reject! { |k, v| k.nil? || v.nil? } if nonnil
    prefixes
  end


  def assert_uri_coercion coerce
    if coerce
      coerce = coerce.to_s.to_sym if coerce.respond_to? :to_s
      raise 'coerce must be either :uri or :rdf' unless
        %i[uri rdf].include?(coerce)
    end
    coerce
  end

  def assert_xml_node node
    raise 'Argument must be a Nokogiri::XML::Element' unless
      node.is_a? Nokogiri::XML::Element
    node
  end

  def internal_subject_for node, prefixes: nil, base: nil, coerce: nil,
      is_ancestor: false

    # note we assign these AFTER the literal check or it will be wrong
    prefixes ||= get_prefixes node

    base ||= get_base node
    base = coerce_resource base, as: :uri unless base

    # answer a bunch of helpful questions about this element
    subject = nil
    parent  = node.parent
    ns_href = node.namespace.href if node.namespace
    up_ok   = %w[rel rev].none? { |a| node.key? a }
    is_root = !parent or parent.document?
    special = /^(?:[^:]+:)?(?:head|body)$/i === node.name and
      (ns_href == 'http://www.w3.org/1999/xhtml' or
      /^(?:[^:]+:)?html$/xi === parent.name)

    # if the node is being inspected as an ancestor to the
    # original node, we have to check it backwards.
    if is_ancestor
      # ah right @resource gets special treatment
      if subject = node[:resource]
        subject = resolve_curie subject,
          prefixes: prefixes, base: base, scalar: true
      else
        # then check @href and @src
        %w[href src].each do |attr|
          if node.key? attr
            # merge with the root and return it
            subject = base + node[attr]
            break
          end
        end
      end

      return coerce_resource subject, as: coerce if subject

      # note if we are being called with is_ancestor, that means
      # the original node (or indeed any of the nodes previously
      # tested) have anything resembling a resource in them. this
      # means @rel/@rev should be ignored, and we should keep
      # looking for a subject.
    end

    if node[:about]

      subject = resolve_curie node[:about],
        prefixes: prefixes, base: base, scalar: true

      # ignore coercion
      return subject if subject.is_a? RDF::Node

    elsif is_root
      subject = base
    elsif special
      subject = internal_subject_for parent
    elsif node[:resource]
      # XXX resolve @about against potential curie
      subject = resolve_curie node[:resource],
        prefixes: prefixes, base: base, scalar: true
    elsif node[:href]
      subject = base + node[:href]
    elsif node[:src]
      subject = base + node[:src]
    elsif node[:typeof]
      # bnode the typeof attr

      # note we return bnodes irrespective of the rdf flag
      return RDF::Node('id-%016x' % node.attributes['typeof'].pointer_id)
    elsif node[:inlist]
      # bnode the inlist attr
      return RDF::Node('id-%016x' % node.attributes['inlist'].pointer_id)
    elsif (parent[:inlist] && %i[href src].none? { |a| parent.key? a }) ||
        (is_ancestor && !up_ok)
      # bnode the element
      return RDF::Node('id-%016x' % node.pointer_id)
      # elsif node[:id]
    else
      subject = internal_subject_for parent, is_ancestor: true
    end

    coerce_resource subject, as: coerce if subject
  end

  MODERNIZE = {
    div: -> e {
      if e.classes.include? 'figure'
        e.remove_class 'figure'
        e.name = 'figure' unless e.parent.name == 'figure'
      else
        e.remove_class 'section'
        e.name = 'section'
      end
    },
    blockquote: -> e {
      e.remove_class 'note'
      e.name = 'aside'
      e['role'] = 'note'
    },
    table: -> e {
      e.remove_class 'figure'
      unless e.parent.name == 'figure'
        inner = e.dup
        markup replace: e, spec: { [inner] => :figure }
      end
    },
    img: -> e {
      e.remove_class 'figure'
      unless e.parent.name == 'figure'
        inner = e.dup
        markup replace: e, spec: { [inner] => :figure }
      end
    },
  }

  # rdf term type tests
  NTESTS = { uri: :"uri?", blank: :"node?", literal: :"literal?" }.freeze
  NMAP   = ({ iri: :uri, bnode: :blank }.merge(
    [:uri, :blank, :literal].map { |x| [x, x] }.to_h)).freeze

  # it is so lame i have to do this
  BITS = { nil => 0, false => 0, true => 1 }

  public

  def coerce_node_spec spec, rev: false
    spec = [spec] unless spec.respond_to? :to_a
    spec = spec - [:resource] + [:uri, :blank] if spec.include? :resource
    raise 'Subjects are never literals' if rev and spec.include? :literal

    spec = NMAP.values_at(*spec).reject(&:nil?).uniq
    spec = NTESTS.keys if spec.empty?
    spec.delete :literal if rev
    spec.uniq
  end

  def node_matches? node, spec
    spec.any? { |k| node.send NTESTS[k] }
  end

  # Obtain all and only the `rdf:type`s directly asserted on the subject.
  # 
  # @param repo [RDF::Queryable]
  # @param subject [RDF::Resource]
  # @param type [RDF::Term, :to_a] override searching for type(s) and
  #  just return what is passed in (XXX why did i do this?)
  # @param struct [Hash] pull from an attribute-value hash rather than
  #  the graph
  #
  # @return [Array]
  def self.asserted_types repo, subject, type = nil, struct: nil
    asserted = nil

    # XXX i don't understand why this condition exists; TODO track it down
    if type
      type = type.respond_to?(:to_a) ? type.to_a : [type]
      asserted = type.select { |t| t.is_a? RDF::Value }.map do |t|
        RDF::Vocabulary.find_term t
      end
    end

    asserted ||= struct ? (struct[RDF.type].dup || []) : repo.query(
      [subject, RDF.type, nil]).objects.map do |o|
      RDF::Vocabulary.find_term o
    end.compact

    asserted.select { |t| t && t.uri? }.uniq
  end

  # Obtain a stack of types for an asserted initial type or set
  # thereof. Returns an array of arrays, where the first is the
  # asserted types and their inferred equivalents, and subsequent
  # elements are immediate superclasses and their equivalents. A given
  # URI will only appear once in the entire structure. When `descend`
  # is set, the resulting array will be flat.
  #
  # @param rdftype [RDF::Term, :to_a]
  # @param descend [true,false] descend instead of ascend
  #
  # @return [Array]
  #
  def type_strata rdftype, descend: false
    # first we coerce this to an array if it isn't already
    rdftype = rdftype.respond_to?(:to_a) ? rdftype.to_a : [rdftype]
      
    # now squash and coerce
    rdftype = rdftype.uniq.map { |t| RDF::Vocabulary.find_term t }.compact

    # bail out early
    return [] if rdftype.empty?

    # essentially what we want to do is construct a layer of
    # asserted classes and their inferred equivalents, then probe
    # the classes in the first layer for subClassOf assertions,
    # which will form the second layer, and so on.

    queue  = [rdftype]
    strata = []
    seen   = Set.new
    qmeth  = descend ? :subClass : :subClassOf 

    while qin = queue.shift
      qwork = []

      qin.each do |q|
        qwork << q # entail doesn't include q
        qwork += q.entail(:equivalentClass) if q.uri?
      end

      # grep and flatten
      qwork = qwork.map do |t|
        next t if t.is_a? RDF::Vocabulary::Term
        RDF::Vocabulary.find_term t
      end.compact.uniq - seen.to_a
      seen |= qwork

      # warn "qwork == #{qwork.inspect}"

      # push current layer out
      strata.push qwork.dup unless qwork.empty?
     
      # now deal with subClassOf
      qnext = []
      qwork.each { |q| qnext += q.send(qmeth) }

      # grep and flatten this too
      qnext = qnext.map do |t|
        next t if t.is_a? RDF::Vocabulary::Term
        RDF::Vocabulary.find_term t
      end.compact.uniq - seen.to_a
      # do not append qsuper to seen!

      # warn "qsuper == #{qsuper.inspect}"

      # same deal, conditionally push the input queue
      queue.push qnext.dup unless qnext.empty?
    end

    # voila
    descend ? strata.flatten : strata
  end

  # XXX this should really go in RDF::Reasoner
  def symmetric? property
    property = RDF::Vocabulary.find_term property rescue return false
    type = type_strata(property.type).flatten
    type.include? RDF::OWL.SymmetricProperty
  end

  # Determine whether one or more `rdf:Class` entities is transitively
  # an `rdfs:subClassOf` or `owl:equivalentClass` of one or more
  # reference types. Returns the subclass "distance" of the "nearest"
  # reference type from the given type(s), or nil if none match.
  #
  # @param type [RDF::Resource, #to_a] the type(s) we are interested in
  # @param reftype [RDF::Resource, #to_a] the reference type(s) to
  #   check against
  #
  # @return [nil, Integer]
  #
  def type_is? type, reftype
    # generate types, including optionally base classes if they aren't
    # already present in the strata (this will be automatically 
    types = type_strata(type)
    bases = [RDF::RDFS.Resource, RDF::OWL.Thing,
             RDF::Vocab::SCHEMA.Thing] - types.flatten
    # put the base classes in last if there are any left after subtracting
    types << bases unless bases.empty?

    # coerce reftype to an array if it isn't already
    reftype = reftype.respond_to?(:to_a) ? reftype.to_a : [reftype]

    # this will return the "distance" of the matching type from what
    # was asserted, starting at 0 (which in ruby is true!) or false
    types.find_index { |ts| !(ts & reftype).empty? }
  end

  # Determine whether a subject is a given `rdf:type`.
  #
  # @param repo [RDF::Queryable] the repository
  # @param subject [RDF::Resource] the resource to test
  # @param type [RDF::Term, #to_a] the type(s) to test the subject against
  # @param struct [Hash] an optional predicate-object set
  #
  # @return [true, false]
  #
  def rdf_type? repo, subject, type, struct: nil
    asserted = asserted_types repo, subject, struct: struct

    # this is handy
    !!type_is?(asserted, type)
  end

  # Obtain the head of a list for a given list subject.
  #
  # @param repo [RDF::Queryable] the repository
  # @param subject [RDF::Node] a node in the list
  #
  # @return [RDF::Node, nil] the head node or nothing
  #
  def self.list_head repo, subject
    nodes = [subject]

    # note we don't 
    while tmp = repo.query(
      [nil, RDF.rest, node]).subjects.select(&:node?).sort.first
      nodes << tmp
    end

    # the last one is the head of the list
    nodes.last
  end

  # Obtain all the predicates that are equivalent to the given predicate(s).
  #
  # @param predicates [RDF::URI,Array]
  #
  # @return [Array]
  #
  def predicate_set predicates, seen: Set.new
    predicates = Set[predicates] if predicates.is_a? RDF::URI
    unless predicates.is_a? Set
      raise "predicates must be a set" unless predicates.respond_to? :to_set
      predicates = predicates.to_set
      end

    # shortcut
    return predicates if predicates.empty?

    raise 'predicates must all be RDF::URI' unless predicates.all? do |p|
      p.is_a? RDF::URI
    end

    # first we generate the set of equivalent properties for the given
    # properties
    predicates += predicates.map do |p|
      p.entail :equivalentProperty
    end.flatten.to_set

    # then we take the resulting set of properties and
    # compute their subproperties
    subp = Set.new
    (predicates - seen).each do |p|
      subp += p.subProperty.flatten.to_set
    end

    # uhh this whole "seen" business might not be necessary
    predicates + predicate_set(subp - predicates - seen, seen: predicates)
  end

  # Returns subjects from the graph with entailment.
  #
  # @param repo
  # @param predicate
  # @param object
  # @param entail
  # @param only
  #
  # @return [RDF::Resource]
  #
  def self.subjects_for repo, predicate, object, entail: true, only: [], &block
    raise "Object must be a Term, not a #{object.class.inspect}" unless
      object.is_a? RDF::Term
    predicate = predicate.respond_to?(:to_a) ? predicate.to_a : [predicate]
    raise 'Predicate must be some kind of term' unless
      predicate.all? { |p| p.is_a? RDF::URI }

    only = coerce_node_spec only, rev: true

    predicate = predicate.map { |x| RDF::Vocabulary.find_term x }.compact
    predicate = predicate_set predicate if entail

    out  = {}
    revp = Set.new
    predicate.each do |p|
      repo.query([nil, p, object]).subjects.each do |s|
        next unless node_matches? s, only

        entry = out[s] ||= [Set.new, Set.new]
        entry.first << p
      end

      # do this here while we're at it
      unless object.literal?
        revp += p.inverseOf.to_set
        revp << p if p.type.include? RDF::OWL.SymmetricProperty
      end
    end

    unless object.literal?
      revp = predicate_set revp if entail

      revp.each do |p|
        repo.query([object, p, nil]).objects.each do |o|
          next unless node_matches? o, only

          entry = out[o] ||= [Set.new, Set.new]
          entry.last << p
        end
      end
    end

    # run this through a block to get access to the predicates
    return out.map { |node, preds| block.call node, *preds } if block

    out.keys
  end

  # Returns objects from the graph with entailment.
  #
  # @param repo
  # @param subject
  # @param predicate
  # @param entail
  # @param only
  # @param datatype
  #
  # @return [RDF::Term]
  #
  def self.objects_for repo, subject, predicate,
      entail: true, only: [], datatype: nil, &block
    raise "Subject must be a resource, not #{subject.inspect}" unless
      subject.is_a? RDF::Resource
    predicate = predicate.respond_to?(:to_a) ? predicate.to_a : [predicate]
    raise "Predicate must be a term, not #{predicate.first.class}" unless
      predicate.all? { |p| p.is_a? RDF::URI }

    predicate = predicate.map { |x| RDF::Vocabulary.find_term x }.compact

    only = coerce_node_spec only

    datatype = (
      datatype.respond_to?(:to_a) ? datatype.to_a : [datatype]).compact
    raise 'Datatype must be some kind of term' unless
      datatype.all? { |p| p.is_a? RDF::URI }

    # fluff this out 
    predicate = predicate_set predicate if entail

    out = {}
    predicate.each do |p|
      repo.query([subject, p, nil]).objects.each do |o|

        # make sure it's in the spec
        next unless node_matches? o, only

        # constrain output
        next if o.literal? and
          !(datatype.empty? or datatype.include?(o.datatype))

        entry = out[o] ||= [Set.new, Set.new]
        entry.first << p
      end
    end

    # now we do the reverse
    unless only == [:literal]
      # generate reverse predicates
      revp = Set.new
      predicate.each do |p|
        revp += p.inverseOf.to_set
        revp << p if p.type.include? RDF::OWL.SymmetricProperty
      end
      revp = predicate_set revp if entail

      # now scan 'em
      revp.each do |p|
        repo.query([nil, p, subject]).subjects.each do |s|
          next unless node_matches? s, only
          # no need to check datatype; subject is never a literal

          entry = out[s] ||= [Set.new, Set.new]
          entry.last << p
        end
      end
    end

    # run this through a block to get access to the predicates
    return out.map { |node, preds| block.call node, *preds } if block

    out.keys
  end

  # Obtain the canonical UUID for the given URI
  #
  # @param repo [RDF::Queryable]
  # @param uri [RDF::URI, URI, to_s] the subject of the inquiry
  # @param unique [true, false] return a single resource/nil or an array
  # @param published [true, false] whether to restrict to published docs
  # @param scache [Hash] subject cache `{ subject => true }`
  # @param ucache [Hash] UUID-to-URI cache `{ uuid => [URIs] }`
  # 
  # @return [RDF::URI, Array]
  #
  def self.canonical_uuid repo, uri, unique: true, published: false,
      scache: {}, ucache: {}, base: nil
    # make sure this is actually a uri
    orig = uri = coerce_resource uri, base
    unless uri.is_a? RDF::Node
      tu = URI(uri_pp(uri).to_s).normalize

      if tu.path && !tu.fragment &&
          UUID_RE.match?(uu = tu.path.delete_prefix(?/))
        tu = URI('urn:uuid:' + uu.downcase)
      end

      # unconditionally overwrite uri
      uri = RDF::URI(tu.to_s)

      # now check if it's a uuid
      if tu.respond_to? :uuid
        # warn "lol uuid #{orig}"
        # if it's a uuid, check that we have it as a subject
        # if we have it as a subject, return it
        return uri if scache[uri] ||= repo.has_subject?(uri)
        # note i don't want to screw around right now dealing with the
        # case that a UUID might not itself be canonical
      end
    end

    # spit up the cache if present
    if out = ucache[orig]
      # warn "lol cached #{orig}"
      return unique ? out.first : out
    end

    # otherwise we proceed:

    # goal: return the most "appropriate" UUID for the given URI

    # warn "WTF URI #{uri}"

    # handle path parameters by generating a bunch of candidates
    uris = if uri.respond_to? :path and uri.path.start_with? ?/
             # split any path parameters off
             uu, *pp = split_pp uri
             if pp.empty?
               [uri] # no path parameters
             else
               uu = RDF::URI(uu.to_s)
               bp = uu.path # base path
               (0..pp.length).to_a.reverse.map do |i|
                 u = uu.dup
                 u.path = ([bp] + pp.take(i)).join(';')
                 u
               end
             end
           else
             [uri] # not a pathful URI
           end

    # rank (0 is higher):
    # * (00) exact & canonical == 0,
    # * (01) exact == 1,
    # * (10) inexact & canonical == 2,
    # * (11) inexact == 3.

    # collect the candidates by URI
    sa = predicate_set [RDF::SAK::CI.canonical,
      RDF::SAK::CI.alias, RDF::OWL.sameAs]
    candidates = nil
    uris.each do |u|
      candidates = subjects_for(repo, sa, u, entail: false) do |s, f|
        # there is no #to_i for booleans and also we xor this number
        [s, { rank: BITS[f.include?(RDF::SAK::CI.canonical)] ^ 1,
          published: published?(repo, s),
          mtime: dates_for(repo, s).last || DateTime.new }]
      end.compact.to_h
      break unless candidates.empty?
    end

    # warn candidates.inspect

    # now collect by slug
    slug = terminal_slug uri, base: base
    if slug and !slug.empty?
      exact = uri == coerce_resource(slug, base) # slug represents exact match
      sl = [RDF::SAK::CI['canonical-slug'], RDF::SAK::CI.slug]
      [RDF::XSD.string, RDF::XSD.token].each do |t|
        subjects_for(repo, sl, RDF::Literal(slug, datatype: t)) do |s, f|
          # default to lowest rank if this candidate is new
          entry = candidates[s] ||= {
            published: published?(repo, s, base: base),
            rank: 0b11, mtime: dates_for(repo, s).last || DateTime.new }
          # true is 1 and false is zero so we xor this too
          rank  = (BITS[exact] << 1 | BITS[f.include?(sl.first)]) ^ 0b11
          # now amend the rank if we have found a better one
          entry[:rank] = rank if rank < entry[:rank]
        end
      end
    end

    candidates.delete_if { |s, _| !/^urn:uuid:/.match?(s.to_s)  }

    # scan all the candidates for replacements and remove any
    # candidates that have been replaced
    candidates.to_a.each do |k, v|
      # note that 
      reps = replacements_for(repo, k, published: published) - [k]
      unless reps.empty?
        v[:replaced] = true
        reps.each do |r|
          c = candidates[r] ||= { rank: v[:rank],
            published: published?(repo, r),
            mtime: dates_for(repo, r).last || v[:mtime] || DateTime.new }
          # we give the replacement the rank and mtime of the
          # resource being replaced if it scores better
          c[:rank]  = v[:rank]  if v[:rank]  < c[:rank]
          c[:mtime] = v[:mtime] if v[:mtime] > c[:mtime]
        end
      end
    end

    # now we can remove all unpublished candidates if the context is
    # published
    candidates.select! do |_, v|
      !v[:replaced] && (published ? v[:published] : true)
    end

    # now we sort by rank and date; the highest-ranking newest
    # candidate is the one

    out = candidates.sort do |a, b|
      _, va = a
      _, vb = b
      cb = published ? BITS[vb[:published]] <=> BITS[va[:published]] : 0
      cr = va[:rank] <=> vb[:rank]
      cb == 0 ? cr == 0 ? vb[:mtime] <=> va[:mtime] : cr : cb
    end.map { |x| x.first }.compact

    # set cache
    ucache[orig] = out

    #warn "lol not cached #{orig}"

    unique ? out.first : out

    # an exact match is better than an inexact one

    # a canonical match is better than non-canonical

    # note this is four bits: exact, canon(exact), inexact, canon(inexact)
    # !canon(exact) should rank higher than canon(inexact)

    # unreplaced is better than replaced

    # newer is better than older (though no reason an older item
    # can't replace a newer one)

    # published is better than not, unless the context is
    # unpublished and an unpublished document replaces a published one
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
          cmp = pref[ah.first == 'www'] <=> pref[bh.first == 'www']
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

  # XXX MAKE THIS LOL
  def self.cmp_literal a, b
  end

  def self.cmp_label repo, a, b, labels: nil, supplant: true, reverse: false
    labels ||= {}

    # try supplied label or fall back
    pair = [a, b].map do |x|
      if labels[x]
        labels[x][1]
      elsif supplant and y = label_for(repo, x)
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

  # Obtain the "best" dereferenceable URI for the subject. Optionally
  # returns all candidates. Pass in a fragment map of the following
  # form:
  #
  # `{ RDFClass => [p1, [p2, true]] }`
  #
  # in order to map subjects to URI fragments. Classes are tested in
  # the order of their "distance" from the asserted type(s). The `[p2,
  # true]` pair indicates the predicate should be evaluated in
  # reverse. Ordinary inverse and symmetric properties, as well as
  # predicates that map to lists, are handled automatically.
  # 
  # @param repo      [RDF::Queryable]
  # @param subject   [RDF::Resource]
  # @param unique    [true, false] flag for unique return value
  # @param rdf       [true, false] flag to specify RDF::URI vs URI 
  # @param slugs     [true, false] flag to include slugs
  # @param subj_only [true, false] flag to constrain candidates to subjects
  # @param fragment  [true, false] flag to include fragment URIs
  # @param frag_map  [Hash] mapping of classes to sequences of
  #   properties forward from the subject
  # @param documents [#to_a] Which classes are considered entire
  #   "documents"
  #
  # @return [RDF::URI, URI, Array]
  #
  def self.canonical_uri repo, subject, base: nil, unique: true, rdf: true,
      slugs: false, subj_only: false, fragment: true, frag_map: {},
      documents: [RDF::Vocab::FOAF.Document]
    subject = coerce_resource subject, base

    # dealing with non-documents (hash vs slash)
    #
    # * if the subject has a ci:canonical that is an HTTP(S) URL, then
    #   use that
    #
    # * if the subject has a type that is equivalent or subclass of
    #   foaf:Document, then it gets a slash url
    #
    # * if the subject however is /not/ a foaf:Document and the
    #   `container` parameter is set then return a fragment identifer
    #   off the container

    # 2021-05-17, the real fragment identifier resolution
    #
    # step 0: check if the subject is ci:fragment-of something. if it
    # is, that's it.
    #
    # step 1: if ci:canonical-uri is a fragment, we need to resolve
    # the document that it is a fragment of. if it exists, great,
    # we're done.
    #
    # step 2: find all the incident neighbours (subjects with this as
    # their object), including objects of the subject with invertible
    # properties
    #
    # step 3: eliminate all resources that are not some kind of
    # foaf:Document
    #
    # step 4: attempt to eliminate all resources that are not
    # bibo:status bs:published; back out if there are none left
    #
    # step 5: if there are still multiple candidates for parent
    # document, pick the ...oldest one i guess? if neither has a
    # dc:date or subproperty thereof associated i guess tiebreak with
    # their canonical URIs?
    #
    # IDEAS FOR HOW TO DO THIS WITH LOUPE
    #
    # Loupe is an extension of SHACL, intended to be the spiritual
    # successor of Fresnel, and also totally not done yet.
    #
    # Loupe lenses can be applied to classes or individual subjects
    # (just like Fresnel but using SHACL mechanisms). The purpose of
    # Loupe, again just like Fresnel, is to provide instructions for
    # serializing arbitrary RDF, including as composite documents
    # containing multiple nested subjects, indeed with nesting that
    # can go arbitrarily deep.
    #
    # This capability is already expressable in SHACL, though Loupe
    # will also need some way to direct the disposition of a
    # subresource to a serializer, i.e. whether to render it as a
    # link, or embed it. Loupe will also have its own tiebreaking
    # mechanism, so determining the fragment-ness of a canonical URI
    # on a given subject will be much easier than the home-spun
    # heuristic currently planned. The solution would involve creating
    # an index of resources that are fragments
    #
    # ###

    # this was rewritten to correctly pick the canonical uri and i
    # have no idea why it wasn't like this before

    # note that canonical/canonical-slug should be functional so
    # should not have multiple entries; in this case we pick the
    # "lowest" lexically purely in the interest of being consistent

    # determine if there is a host document
    host = objects_for(repo, subject, RDF::SAK::CI['fragment-of'],
      only: :resource).sort { |a, b| cmp_resource a, b }.first

    # just get the asserted types since we'll use em more than once
    types = asserted_types(repo, subject)

    # here is where we determine the host document if it hasn't
    # already been identified. note that we assume foaf:Document
    # entities are never fragments (even bibo:DocumentFragment!)
    unless host or type_is?(types, documents)
      # try to find a list head
      head = subjects_for(repo, RDF.first, subject, only: :blank).sort.first
      head = list_head(repo, head) if head
      preds = frag_map.map do |k, v| 
        score = type_is?(types, k) or next
        # wrap v in an array and wrap it again if necessary
        v = v.respond_to?(:to_a) ? v.to_a : [v]
        v = [v] if v.size == 2 and v.first.is_a?(RDF::Value) and
          !v.last.is_a?(RDF::Value) and !v.last.respond_to?(:to_a)
        # now we coerce to pairs
        v.map! { |pair| pair.respond_to?(:to_a) ? pair.to_a : [pair, false] }
        [score, v]
      end.compact.sort { |a, b|
        a.first <=> b.first }.map(&:last).flatten(1).uniq

      # accumulate candidate hosts
      hosts = []
      preds.each do |pair|
        pred, rev = pair
        if rev
          hosts += subjects_for(repo, pred, subject, only: :resource)
          hosts += subjects_for(repo, pred, head, only: :resource) if head
        else
          hosts += objects_for(repo, subject, pred, only: :resource)
        end
      end

      # now we filter them
      hosts = hosts.uniq.select do |h|
        rdf_type?(repo, h, documents) and published?(repo, h)
      end

      # the first one will be our baby
      host = hosts.first
    end

    # Get the canonical uri for the host!
    hosturi = canonical_uri(repo, host, base: base) if host 

    # first thing: get ci:canonical
    primary = objects_for(repo, subject, RDF::SAK::CI.canonical,
                          only: :resource).sort { |a, b| cmp_resource a, b }
    # if that's empty then try ci:canonical-slug
    if subject.uri? and (host or slugs) and (primary.empty? or not unique)
      primary += objects_for(repo, subject,
        RDF::SAK::CI['canonical-slug'], only: :literal).map do |o|
        if hosturi
          h = hosturi.dup
          h.fragment = o.value
          h
        else
          base + o.value 
        end
      end.sort { |a, b| cmp_resource a, b }
    end

    # if the candidates are *still* empty, do the same thing but for
    # owl:sameAs (ci:alias) etc
    secondary = []
    if primary.empty? or not unique
      secondary = objects_for(repo, subject, RDF::OWL.sameAs,
        entail: false, only: :resource).sort { |a, b| cmp_resource a, b }

      if subject.uri? and (slugs or host)
        secondary += objects_for(repo, subject, RDF::SAK::CI.slug,
          entail: false, only: :literal).map do |o|
          if hosturi
            h = hosturi.dup
            h.fragment = o.value
            h
          else
            base + o.value 
          end
        end.sort { |a, b| cmp_resource a, b }
      end

      # in the final case, append the UUID to the base
      uri = URI(uri_pp subject.to_s)
      if base and uri.respond_to? :uuid
        if hosturi
          h = hosturi.dup
          h.fragment = UUID::NCName.to_ncname(uri.uuid, version: 1)
          secondary << h
        else
          b = base.clone
          b.query = b.fragment = nil
          b.path = '/' + uri.uuid
          secondary << RDF::URI.new(b.to_s)
        end
      else
        secondary << subject
      end
    end

    # now we merge the two lists together
    out = primary + secondary

    # remove all URIs with fragments unless specified
    unless fragment
      tmp = out.reject(&:fragment)
      out = tmp unless tmp.empty?
    end

    # coerce to URI objects if specified
    out.map! { |u| URI(uri_pp u.to_s) } unless rdf

    unique ? out.first : out.uniq
  end

  # Determine whether the URI represents a published document.
  # 
  # @param repo
  # @param uri
  # 
  # @return [true, false]
  def self.published? repo, uri,
      circulated: false, retired: false, indexed: false, base: nil
    uri = coerce_resource uri, base

    if indexed
      ix = objects_for(repo, uri, RDF::SAK::CI.indexed, only: :literal).first
      return false if ix and ix.object == false
    end

    candidates = objects_for(
      repo, uri, RDF::Vocab::BIBO.status, only: :resource).to_set

    return false if !retired and candidates.include? RDF::SAK::CI.retired

    test = Set[RDF::Vocab::BIBO['status/published']]
    test << RDF::SAK::CI.circulated if circulated

    # warn candidates, test, candidates & test

    !(candidates & test).empty?
  end

  # Obtain a key-value structure for the given subject, optionally
  # constraining the result by node type (:resource, :uri/:iri,
  # :blank/:bnode, :literal)
  #
  # @param repo 
  # @param subject of the inquiry
  # @param rev map in reverse
  # @param only one or more node types
  # @param uuids coerce resources to if possible
  #
  # @return [Hash]
  #
  def self.struct_for repo, subject, base: nil, rev: false, only: [],
      inverses: false, uuids: false, canon: false, ucache: {}, scache: {}
    only = coerce_node_spec only

    # coerce the subject
    subject = canonical_uuid(repo, subject,
      base: base, scache: scache, ucache: ucache) || subject if uuids 

    rsrc = {}
    pattern = rev ? [nil, nil, subject] : [subject, nil, nil]
    repo.query(pattern) do |stmt|
      # this will skip over any term not matching the type
      node = rev ? stmt.subject : stmt.object
      next unless node_matches? node, only

      # coerce the node to uuid if told to
      if node.resource?
        if uuids
          uu = canonical_uuid(repo, node, scache: scache, ucache: ucache) unless
            ucache.key? node
          node = uu || (canon ? canonical_uri(repo, node) : node)
        elsif canon
          node = canonical_uri(repo, node)
        end
      end

      if node # may have been set to nil by the previous operation
        p = RDF::Vocabulary.find_term(stmt.predicate) || stmt.predicate
        o = rsrc[p] ||= []
        o << node
      end
    end

    # add inverseOf and symmetric proprties
    if inverses and only != [:literal]
      pattern = rev ? [subject, nil, nil] : [nil, nil, subject]
      repo.query(pattern) do |stmt|
        node = rev ? stmt.object : stmt.subject
        next unless node_matches? node, only

        # i mean it's unlikely that there is more than one inverse
        # predicate but not impossible
        invs = (stmt.predicate.inverseOf || []).dup
        invs << stmt.predicate if symmetric? stmt.predicate
        invs.each do |inverse|
          # coerce the node to uuid if told to
          if node.resource?
            if uuids
              uu = canonical_uuid(repo, node,
                scache: scache, ucache: ucache) unless ucache.key? node
              node = uu || (canon ? canonical_uri(repo, node) : node)
            elsif canon
              node = canonical_uri(repo, node)
            end
          end

          # node may be nil from the resolution attempt above
          (rsrc[inverse] ||= []) << node if node
        end
      end
    end

    # XXX in here we can do fun stuff like filter/sort by language/datatype
    rsrc.values.each { |v| v.sort!.uniq! }

    rsrc
  end

  # Obtain the most appropriate label(s) for the subject's type(s).
  # Returns one or more (depending on the `unique` flag)
  # predicate-object pairs in order of preference.
  #
  # @param repo    [RDF::Queryable]
  # @param subject [RDF::Resource]
  # @param unique [true, false] only return the first pair
  # @param type [RDF::Term, Array] supply asserted types if already retrieved
  # @param lang [nil] not currently implemented (will be conneg)
  # @param desc [false, true] retrieve description instead of label
  # @param alt  [false, true] retrieve alternate instead of main
  #
  # @return [Array] either a predicate-object pair or an array of pairs.
  #
  def self.label_for repo, subject, candidates: nil, unique: true, type: nil,
      lang: nil, desc: false, alt: false, base: nil
    raise ArgumentError, 'no repo!' unless repo.is_a? RDF::Queryable
    return unless subject.is_a? RDF::Value and subject.resource?
    
    asserted = asserted_types repo, subject, type

    # get all the inferred types by layer; add default class if needed
    strata = type_strata asserted
    strata.push [RDF::RDFS.Resource] if
      strata.empty? or not strata.last.include?(RDF::RDFS.Resource)

    # get the key-value pairs for the subject
    candidates ||= struct_for repo, subject, only: :literal

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
    unique ? accum.first : accum.uniq
    
    # what we want to do is match the predicates from the subject to
    # the predicates in the label designation
    
    # get label predicate stack(s) for RDF type(s)
    
    # get all predicates in order (use alt stack if doubly specified)
    
    # filter out desired language(s)
    
    # XXX note we will probably want to return the predicate as well
  end

  # Assuming the subject is a thing that has authors, return the
  # list of authors. Try bibo:authorList first for an explicit
  # ordering, then continue to the various other predicates.
  #
  # @param repo    [RDF::Queryable]
  # @param subject [RDF::Resource]
  # @param unique  [false, true] only return the first author
  # @param contrib [false, true] return contributors instead of authors
  #
  # @return [RDF::Value, Array]
  #
  def authors_for repo, subject, unique: false, contrib: false, base: nil
    authors = []

    # try the author list
    lp = [RDF::Vocab::BIBO[contrib ? :contributorList : :authorList]]
    lp += lp.first.entail(:equivalentProperty) # XXX cache this
    lp.each do |pred|
      o = repo.first_object([subject, pred, nil])
      next unless o
      # note this use of RDF::List is not particularly well-documented
      authors += RDF::List.from(repo, o).to_a
    end

    # now try various permutations of the author/contributor predicate
    unsorted = []
    preds = contrib ? CONTRIB : AUTHOR
    preds.each do |pred|
      unsorted += repo.query([subject, pred, nil]).objects
    end

    # prefetch the author names
    labels = authors.map { |a| [a, label_for(repo, a)] }.to_h

    authors += unsorted.uniq.sort { |a, b| labels[a] <=> labels[b] }

    unique ? authors.first : authors.uniq
  end

  # Find the terminal replacements for the given subject, if any exist.
  #
  # @param repo
  # @param subject
  # @param published indicate the context is published
  #
  # @return [Set]
  #
  def self.replacements_for repo, subject, published: true, base: nil
    subject = coerce_resource subject, base

    # `seen` is a hash mapping resources to publication status and
    # subsequent replacements. it collects all the resources in the
    # replacement chain in :fwd (replaces) and :rev (replaced-by)
    # members, along with a boolean :pub. `seen` also performs a
    # duty as cycle-breaking sentinel.

    seen  = {}
    queue = [subject]
    while (test = queue.shift)
      # fwd is "replaces", rev is "replaced by"
      entry = seen[test] ||= {
        pub: published?(repo, test), fwd: Set.new, rev: Set.new }
      queue += (
        subjects_for(repo, RDF::Vocab::DC.replaces, subject) +
          objects_for(repo, subject, RDF::Vocab::DC.isReplacedBy,
          only: :resource)
      ).uniq.map do |r| # r = replacement
        next if seen.include? r
        seen[r] ||= { pub: published?(repo, r), fwd: Set.new, rev: Set.new }
        seen[r][:fwd] << test
        entry[:rev] << r
        r
      end.compact.uniq
    end

    # if we're calling from a published context, we return the
    # (topologically) last published resource(s), even if they are
    # replaced ultimately by unpublished resources.
      
    out = seen.map { |k, v| v[:rev].empty? ? k : nil }.compact - [subject]

    # now we modify `out` based on the publication status of the context
    if published
      pubout = out.select { |o| seen[o][:pub] }
      # if there is anything left after this, return it
      return pubout unless pubout.empty?
      # now we want to find the penultimate elements of `seen` that
      # are farthest along the replacement chain but whose status is
      # published

      # start with `out`, take the union of their :fwd members, then
      # take the subset of those which are published. if the result
      # is empty, repeat. (this is walking backwards through the
      # graph we just walked forwards through to construct `seen`)
      loop do
        # XXX THIS NEEDS A TEST CASE
        out = seen.values_at(*out).map { |v| v[:fwd] }.reduce(:+).to_a
        break if out.empty?
        pubout = out.select { |o| seen[o][:pub] }
        return pubout unless pubout.empty?
      end
    end

    out
  end

  # Obtain dates for the subject as instances of Date(Time). This is
  # just shorthand for a common application of `objects_for`.
  #
  # @param repo
  # @param subject
  # @param predicate
  # @param datatype
  #
  # @return [Array] of dates
  #
  def self.dates_for repo, subject, predicate: RDF::Vocab::DC.date,
      datatype: [RDF::XSD.date, RDF::XSD.dateTime]
    objects_for(
      repo, subject, predicate, only: :literal, datatype: datatype) do |o|
      o.object
    end.sort.uniq
  end

  # Obtain any specified MIME types for the subject. Just shorthand
  # for a common application of `objects_for`.
  #
  # @param repo
  # @param subject
  # @param predicate
  # @param datatype
  #
  # @return [Array] of internet media types
  #
  def formats_for repo, subject, predicate: RDF::Vocab::DC.format,
      datatype: [RDF::XSD.token]
    objects_for(
      repo, subject, predicate, only: :literal, datatype: datatype) do |o|
      t = o.object
      t =~ /\// ? RDF::SAK::MimeMagic.new(t.to_s.downcase) : nil
    end.compact.sort.uniq
  end

  def self.base_for xmlnode, base
    base = URI(base.to_s) unless base.is_a? URI
    out  = base

    if xmlnode.at_xpath('self::html:*|/html', XPATHNS)
      b = URI(xmlnode.at_xpath(XPATH[:htmlbase], XPATHNS).to_s.strip)
      
      out = b if b.absolute?
    elsif b = xmlnode.root.at_xpath(XPATH[:xmlbase])
      b = URI(b.to_s.strip)
      out = b if b.absolute?
    end

    out
  end

  # Traverse links based on content type.
  def self.traverse_links node, type: 'application/xhtml+xml', &block
    enum_for :traverse_links, node, type: type unless block
    type  = type.strip.downcase.gsub(/\s*;.*/, '')
    xpath = LINK_MAP.fetch type, XPATH[:xlinks]
    node.xpath(xpath, XPATHNS).each { |node| block.call node }
  end

  # XXX OTHER STUFF

  # isolate an element into a new document
  def subtree doc, xpath = '/*', reindent: true, prefixes: {}
    # at this time we shouldn't try to do anything cute with the xpath
    # even though it is attractive to want to prune out prefixes

    # how about we start with a noop
    return doc.root.dup if xpath == '/*'

    begin
      nodes = doc.xpath xpath, prefixes
      return unless
        nodes and nodes.is_a?(Nokogiri::XML::NodeSet) and !nodes.empty?
      out = Nokogiri::XML::Document.new
      out << nodes.first.dup
      reindent out.root if reindent
      out
    rescue Nokogiri::SyntaxError
      return
    end
  end

  # reindent text nodes
  def reindent node, depth = 0, indent = '  '
    kids = node.children
    if kids and child = kids.first
      loop do
        if child.element?
          # recurse into the element
          reindent child, depth + 1, indent
        elsif child.text?
          text = child.content || ''

          # optional horizontal whitespace followed by at least
          # one newline (we don't care what kind), followed by
          # optional horizontal or vertical whitespace
          preamble = !!text.gsub!(/\A[ \t]*[\r\n]+\s*/, '')

          # then we don't care what's in the middle, but hey let's get
          # rid of dos newlines because we can always put them back
          # later if we absolutely have to
          text.gsub!(/\r+/, '')

          # then optionally any whitespace followed by at least
          # another newline again, followed by optional horizontal
          # whitespace and then the end of the string
          epilogue = !!text.gsub!(/\s*[\r\n]+[ \t]*\z/, '')

          # if we prune these off we'll have a text node that is
          # either the empty string or it isn't (note we will only
          # register an epilogue if the text has some non-whitespace
          # in it, because otherwise the first regex would have
          # snagged everything, so it's probably redundant)

          # if it's *not* empty then we *prepend* indented whitespace
          if preamble and !text.empty?
            d = depth + (child.previous ? 1 : 0)
            text = "\n" + (indent * d) + text
          end
 
          # then we unconditionally *append*, (modulo there being a
          # newline in the original at all), but we have to check by
          # how much: if this is *not* the last node then depth + 1,
          # otherwise depth
          if preamble or epilogue
            d = depth + (child.next ? 1 : 0)
            text << "\n" + (indent * d)
          end

          child.content = text
        end

        break unless child = child.next
      end
    end

    node
  end

  # ehh idea was to rip through the spec and rewrite urls but there
  # are too many wildcards
  # def rewrite_spec spec, base, prefixes, vocab = nil, inline: false
  #   case spec
  #   when Hash
  #     # 
  #   when Nokogiri::XML::Node
  #     if inline
  #     end
  #   when -> x { x.is_a?(Array) or x.respond_to? :to_a }
  #     spec.to_a.map { |x| rewrite_spec x, base, prefixes, vocab }
  #   end
  #
  #   spec
  # end

  XHTMLNS = 'http://www.w3.org/1999/xhtml'.freeze
  XHV     = 'http://www.w3.org/1999/xhtml/vocab#'.freeze
  XPATHNS = {
    html:  XHTMLNS,
    svg:   'http://www.w3.org/2000/svg',
    atom:  'http://www.w3.org/2005/Atom',
    xlink: 'http://www.w3.org/1999/xlink',
  }.freeze

  ######## URI STUFF ########

  # Preprocess a URI string so that it can be handed to +URI.parse+
  # without crashing.
  #
  # @param uri   [#to_s] The URI string in question
  # @param extra [#to_s] Character class of any extra characters to escape
  # @return [String] The sanitized (appropriately escaped) URI string

  # really gotta stop carting this thing around
  def uri_pp uri, extra = ''
    # take care of malformed escapes
    uri = uri.to_s.b.gsub(/%(?![0-9A-Fa-f]{2})/n, '%25')
    uri.gsub!(/([#{Regexp.quote extra}])/) do |s|
      sprintf('%%%02X', s.ord)
    end unless extra.empty?
    # we want the minimal amount of escaping so we split out the separators
    out = ''
    parts = RFC3986.match(uri).captures
    parts.each_index do |i|
      next if parts[i].nil?
      out << SEPS[i].first
      out << parts[i].b.gsub(SF) { |s| sprintf('%%%02X', s.ord) }
      out << SEPS[i].last
    end

    # make sure escaped hex is upper case like the rfc says
    out.gsub(/(%[0-9A-Fa-f]{2})/) { |x| x.upcase }
  end

  # Given a URI as input, split any query parameters into an array of
  # key-value pairs. If +:only+ is true, this will just return the
  # pairs. Otherwise it will prepend the query-less URI to the array,
  # and can be captured with an idiom like +uri, *qp = split_qp uri+.
  #
  # @param uri [URI,#to_s] The URI to extract parameters from
  # @param only [false, true] whether to only return the parameters
  # @return [Array] (See description)
  #
  def split_qp uri, only: false
    uri = URI(uri_pp uri.to_s) unless uri.is_a? URI
    qp  = URI::decode_www_form(uri.query)
    return qp if only
    uri.query = nil
    [uri] + qp
  end

  # Given a URI as input, split any path parameters out of the last
  # path segment. Works the same way as #split_pp.
  #
  # @param uri [URI,#to_s] The URI to extract parameters from
  # @param only [false, true] whether to only return the parameters
  # @return [Array] (See description)
  #
  def split_pp uri, only: false
    begin
      u = (uri.is_a?(URI) ? uri : URI(uri_pp uri.to_s)).normalize

    rescue URI::InvalidURIError => e
      # these stock error messages don't even tell you what the uri is
      raise URI::InvalidURIError, "#{e.message} (#{uri.to_s})"
    end

    return only ? [] : [uri] unless u.path
    uri = u

    ps = uri.path.split '/', -1
    pp = ps.pop.split ';', -1
    bp = (ps + [pp.shift]).join '/'
    uri = uri.dup

    begin
      uri.path = bp
    rescue URI::InvalidURIError => e
      # these stock error messages don't even tell you what the uri is
      m = e.message
      raise URI::InvalidURIError, "#{m} (#{uri.to_s}, #{bp})"
    end

    return pp if only
    [uri] + pp
  end

  def split_pp2 path, only: false
    # ugh apparently we need a special case for ''.split
    return only ? [] : [''] if !path or path.empty?

    ps = path.to_s.split ?/, -1    # path segments
    pp = ps.pop.to_s.split ?;, -1  # path parameters
    bp = (ps + [pp.shift]).join ?/ # base path

    only ? pp : [bp] + pp
  end

  # Coerce a stringlike argument into a URI. Raises an exception if
  # the string can't be turned into a valid URI. Optionally resolves
  # against a +base+, and the coercion can be tuned to either URI or
  # RDF::URI via +:as+.
  #
  # @param arg [URI, RDF::URI, #to_s] The input string
  # @param base [URI, RDF::URI, #to_s] The optional base URI
  # @param as [:rdf, :uri, nil] The optional coercion type
  # @return [URI, RDF::URI, String]
  #
  def coerce_resource arg, base = nil, as: :rdf
    as = assert_uri_coercion as
    return arg if as and arg.is_a?({ uri: URI, rdf: RDF::URI }[as])
    raise ArgumentError, 'arg must be stringable' unless arg.respond_to? :to_s

    arg = arg.to_s.strip

    if arg.start_with? '_:' and as
      # override the coercion if this is a blank node
      as = :rdf
    elsif base
      begin
        arg = (base.is_a?(URI) ? base : URI(uri_pp base.to_s.strip)).merge arg
      rescue URI::InvalidURIError => e
        warn "attempted to coerce #{arg} which turned out to be invalid: #{e}"
        return
      end
    end

    URI_COERCIONS[as].call arg
  end

  # Coerce a stringlike argument into a UUID URN. Will
  def coerce_uuid_urn arg, base = nil
    # if this is an ncname then change it
    if ([URI, RDF::URI] & arg.class.ancestors).empty? &&
        arg.respond_to?(:to_s)
      arg = arg.to_s

      # coerce ncname to uuid
      arg = UUID::NCName::from_ncname(arg, version: 1) if arg =~
        /^[A-P](?:[0-9A-Z_-]{20}|[2-7A-Z]{24})[A-P]$/i

      # now the string is either a UUID or it isn't
      arg = "urn:uuid:#{arg}" unless arg.start_with? 'urn:uuid:'
    else
      arg = arg.class.new arg.to_s.downcase unless arg == arg.to_s.downcase
    end

    raise ArgumentError, 'not a UUID' unless
      arg.to_s =~ /^urn:uuid:[0-9a-f]{8}(?:-[0-9a-f]{4}){4}[0-9a-f]{8}$/

    arg = coerce_resource arg, base
  end

  # Get the last non-empty path segment of the URI
  #
  # @param uri
  #
  # @return [String]
  def terminal_slug uri, base: nil
    uri = coerce_resource uri, base
    return unless uri.respond_to? :path
    if p = uri.path
      if p = /^\/+(.*?)\/*$/.match(p)
        if p = p[1].split(/\/+/).last
          # we need to escape colons or it will think it's absolute
          return uri_pp(p.split(/;+/).first || '', ':')
        end
      end        
    end
    ''
  end

  # Resolve a string or array or attribute node containing one or more
  # terms/CURIEs against a set of prefixes. The CURIE can be a string,
  # Nokogiri::XML::Attr, or an array thereof. Strings are stripped and
  # split on whitespace. +:prefixes+ and +:base+ can be supplied or
  # gleaned from +:refnode+, which itself can be gleaned if +curie+ is
  # a Nokogiri::XML::Attr. Returns an array of (attempted) resolved
  # terms unless +:scalar+ is true, in which case only the first URI
  # is returned. When +:noop+ is true, this method will always return
  # a value. Can coerce results to either RDF::URI or URI objects.
  #
  # @note +:vocab+ overrides, and is the same as supplying
  #  +prefix[nil]+. It is only meaningful when +:term+ (i.e., when we
  #  expect the input to be an RDFa term) is true.
  #
  # @param curie [#to_s, Nokogiri::XML::Attr,Array] One or more CURIEs
  # @param prefixes [#to_h] The hash of prefixes (nil key is equivalent
  #  to vocab)
  # @param vocab [nil,#to_s] An optional base URI
  # @param refnode [nil, Nokogiri::XML::Element] A reference node for resolution
  # @param term [false, true] Whether to treat the input as an RDFa _term_
  # @param noop [true, false] Whether to skip if the CURIE can't be resolved
  # @param scalar [false, true] Whether to return a scalar value
  # @param coerce [nil, :rdf, :uri] Desired type coercion for the output
  #
  # @return [nil,URI,RDF::URI,Array<nil,URI,RDF::URI>]
  #
  def resolve_curie curie, prefixes: {}, vocab: nil, base: nil,
      refnode: nil, term: false, noop: true, scalar: false, coerce: nil
    prefixes = sanitize_prefixes prefixes

    raise 'coerce must be either :uri or :rdf' if coerce and
      not %i[uri rdf].include?(coerce)

    # coerce curie to its value and set refnode if not present
    if curie.is_a? Nokogiri::XML::Attr
      refnode ||= curie.parent
      curie = curie.value.strip.split
    elsif curie.respond_to? :to_a
      curie = curie.to_a
      raise ArgumentError,
        'if curie is an array, it has to be all strings' unless
        curie.all? { |x| x.respond_to? :to_s }
      curie = curie.map { |x| x.to_s.strip.split }.flatten
    else
      raise ArgumentError, 'curie must be stringable' unless
        curie.respond_to? :to_s
      curie = curie.to_s.strip.split
    end

    if refnode
      raise ArgumentError, 'refnode must be an element' unless
        refnode.is_a? Nokogiri::XML::Element
      prefixes = get_prefixes refnode if prefixes.empty?
    end

    # now we overwrite the vocab
    if vocab
      raise ArgumentError, 'vocab must be stringable' unless
        vocab.respond_to? :to_s
      prefixes[nil] = vocab.to_s.strip
    end

    out = curie.map do |c|
      prefix, slug = /^\[?(?:([^:]+):)?(.*?)\]?$/.match(c).captures
      prefix = prefix.to_sym if prefix
      tmp = if prefixes[prefix]
              prefixes[prefix] + slug
            else
              noop ? c : nil
            end
      tmp && coerce ? URI_COERCIONS[coerce].call(tmp) : tmp
    end

    scalar ? out.first : out
  end

  # Abbreviate one or more URIs into one or more CURIEs if we
  # can. Will through if +noop:+ is true, or if false, return nil for
  # any URI that can't be abbreviated this way. Takes a hash of
  # prefix-URI mappings where the keys are assumed to be symbols or
  # +nil+ to express the current vocabulary, which can be overridden
  # via +vocab:+.
  #
  # @note Only +noop: true+ can be guaranteed to return a value.
  #
  # @param term [Array<#to_s>, #to_s] the term(s)
  # @param prefixes [Hash<Symbol,nil>, #to_h] the prefix mappings
  # @param vocab [#to_s] current vocabulary, overrides +prefixes[nil]+
  # @param noop [true, false] whether or not to pass terms through
  # @param sort [true, false] whether or not to sort (only if +noop:+)
  # @return [String, nil, Array<String,nil>] the (maybe) abbreviated term(s)
  #
  def abbreviate term, prefixes: {}, vocab: nil, noop: true, sort: true
    # this returns a duplicate that we can mess with
    prefixes = sanitize_prefixes prefixes

    # sanitize vocab
    raise ArgumentError, 'vocab must be nil or stringable' unless
      vocab.nil? or vocab.respond_to? :to_s
    prefixes[nil] = vocab.to_s if vocab
    scalar = true

    term = if term.respond_to? :to_a
             scalar = false
             term.to_a
           else [term]; end

    rev = prefixes.invert

    term.map! do |t|
      t = t.to_s
      slug = nil # we want this value to be nil if no match and !noop

      # try matching each prefix URI from longest to shortest
      rev.sort { |a, b| b.first.length <=> a.first.length }.each do |uri, pfx|
        slug = t.delete_prefix uri
        # this is saying the URI either doesn't match or abbreviates to ""
        if slug == t or pfx.nil? && slug.empty?
          slug = nil
        else
          # it's already a slug so we add a prefix if there is one
          slug = '%s:%s' % [pfx, slug] unless pfx.nil?
          break # we have our match
        end
      end

      # at this point slug is either an abbreviated term or nil, so:
      slug ||= t if noop
      slug
    end

    # only sort if noop is set
    term.sort! if noop && sort

    scalar ? term.first : term
  end

  # Find a subset of a struct for a given set of predicates,
  # optionally inverting to give the objects as keys and predicates as
  # values.
  #
  # @param struct [Hash]
  # @param preds  [RDF::URI, #to_a]
  # @param entail [true, false] whether to entail the predicate(s)
  # @param invert [true, false] whether to invert the resulting hash
  #
  # @return [Hash] the selected subset (which could be empty)
  #
  def find_in_struct struct, preds, entail: false, invert: false
    raise ArgumentError, 'preds must not be nil' if preds.nil?
    preds = preds.respond_to?(:to_a) ? preds.to_a : [preds]
    preds = predicate_set preds if entail

    struct = struct.select { |p, _| preds.include? p }

    invert ? invert_struct(struct) : struct
  end

  ######## RDFA/XML STUFF ########

  # Returns the base URI from the perspective of the given element.
  # Can optionally be coerced into either a URI or RDF::URI. Also
  # takes a default value.
  #
  # @param elem [Nokogiri::XML::Node] the context element
  # @param default [nil, #to_s] the default URI
  # @param coerce [nil, :uri, :rdf] the coercion scheme, if any
  # @return [nil, String, URI, RDF::URI] the context's base URI
  def get_base elem, default: nil, coerce: nil
    assert_uri_coercion coerce

    if elem.document?
      elem = elem.root
      return unless elem
    end

    # get the xpath
    xpath = (elem.namespace && elem.namespace.href == XHTMLNS or
      elem.at_xpath('/html')) ? :htmlbase : :xmlbase

    # now we go looking for the attribute
    if base = elem.at_xpath(XPATH[xpath], XPATHNS)
      base = base.value.strip
    else
      base = default.to_s.strip if default
    end

    # clear it out if it's the empty string
    base = nil if base and base.empty?

    # eh that's about all the input sanitation we're gonna get
    base && coerce ? URI_COERCIONS[coerce].call(base) : base
  end

  # Given an X(HT)ML element, returns a hash of prefixes of the form
  # +{ prefix: "vocab" }+, where the current +@vocab+ is represented
  # by the +nil+ key. An optional +:traverse+ parameter can be set to
  # +false+ to prevent ascending the node tree. Any XML namespace
  # declarations are superseded by the +@prefix+ attribute. Returns
  # any +@vocab+ declaration found as the +nil+ key.
  #
  # @note The +descend: true+ parameter assumes we are trying to
  #  collect all the namespaces in use in the entire subtree, rather
  #  than resolve any particular CURIE. As such, the _first_ prefix
  #  mapping in document order is preserved over subsequent/descendant
  #  ones.
  #
  # @param elem [Nokogiri::XML::Node] The context element
  # @param traverse [true, false] whether or not to traverse the tree
  # @param coerce [nil, :rdf, :uri] a type coercion for the URIs, if any
  # @param descend [false, true] go _down_ the tree instead of up
  # @return [Hash] Depending on +:traverse+, either all prefixes
  #  merged, or just the ones asserted in the element.
  def get_prefixes elem, traverse: true, coerce: nil, descend: false
    coerce = assert_uri_coercion coerce

    # deal with a common phenomenon
    elem = elem.root if elem.is_a? Nokogiri::XML::Document

    # get namespace definitions first
    prefix = elem.namespaces.reject do |k, _| k == 'xmlns'
    end.transform_keys { |k| k.split(?:)[1].to_sym }

    # now do the prefix attribute
    if elem.key? 'prefix'
      # XXX note this assumes largely that the input is clean
      elem['prefix'].strip.split.each_slice(2) do |k, v|
        pfx = k.split(?:).first or next # otherwise error
        prefix[pfx.to_sym] = v
      end
    end

    # encode the vocab as the null prefix
    if vocab = elem['vocab']
      vocab.strip!
      # note that a specified but empty @vocab means kill any existing vocab
      prefix[nil] = vocab.empty? ? nil : vocab
    end

    # don't forget we can coerce
    prefix.transform_values! { |v| COERCIONS[coerce].call v } if coerce

    # don't proceed if `traverse` is false
    return prefix unless traverse

    # save us having to recurse in ruby by using xpath implemented in c
    xpath = '%s::*[namespace::*|@prefix|@vocab]' %
      (descend ? :descendant : :ancestor)
    elem.xpath(xpath).each do |e|
      # this will always merge our prefix on top irrespective of direction
      prefix = get_prefixes(e, traverse: false, coerce: coerce).merge prefix
    end

    prefix
  end

  # Given an X(HT)ML element, return the nearest RDFa _subject_.
  # Optionally takes +:prefix+ and +:base+ parameters which override
  # anything found in the document tree.
  #
  # @param node [Nokogiri::XML::Element] the node
  # @param prefixes [Hash] Prefix mapping. Overrides derived values.
  # @param base [#to_s,URI,RDF::URI] Base URI, overrides as well.
  # @param coerce [nil, :rdf, :uri] the coercion regime
  #
  # @return [URI,RDF::URI,String] the subject
  #
  def subject_for node, prefixes: nil, base: nil, coerce: :rdf
    assert_xml_node node
    coerce = assert_uri_coercion coerce

    if n = node.at_xpath(XPATH[:literal])
      return internal_subject_for n,
        prefixes: prefixes, base: base, coerce: coerce
    end

    internal_subject_for node, prefixes: prefixes, base: base, coerce: coerce
  end

  # 
  def modernize doc
    doc.xpath(XPATH[:modernize], XPATHNS).each do |e|
      # gotta instance_exec because `markup` is otherwise unbound
      instance_exec e, &MODERNIZE[e.name.to_sym]
    end
  end

  # Scan definition 
  def scan_terms node, prefixes: nil, base: nil, coerce: :rdf, &block
    node.xpath(XPATH[:rehydrate], XPATHNS).map do |e|
      # extract some useful bits from the thing
      subject = subject_for e, prefixes: prefixes, base: base, coerce: coerce
      text    = (e.content || '').strip
      title   = e[:title].strip if e.key? 'title' and !e[:title].empty?

      next unless !text.empty? or title

      # run the block if there is one
      block.call subject, e, text, title if block

      [subject, e, text, title]
    end.compact
  end

  # Strip all the links surrounding and RDFa attributes off
  # +dfn+/+abbr+/+span+ tags. Assuming a construct like +<a
  # rel="some:relation" href="#..." typeof="skos:Concept"><dfn
  # property="some:property">Term</dfn></a>+ is a link to a glossary
  # entry, this method returns the term back to an undecorated state
  # (+<dfn>Term</dfn>+).

  def dehydrate doc
    doc.xpath(XPATH[:dehydrate], XPATHNS).each do |e|
      e = e.replace e.elements.first.dup
      %w[about resource typeof rel rev property datatype].each do |a|
        e.delete a if e.key? a
      end
    end
  end

  # Scan all the +dfn+/+abbr+/+span+ tags in the document that are not
  # already wrapped in a link. This method scans the text (or
  # +@content+) of each element and compares it to the contents of the
  # graph. If the process locates a subject, it will use that subject
  # as the basis of a link. if there are zero subjects, or more than
  # one, then the method executes a block which can be used to pick
  # (e.g., via user interface) a definite subject or otherwise add one.

  # (maybe add +code+/+kbd+/+samp+/+var+/+time+ one day too)

  def rehydrate doc, graph, &block
    doc.xpath(XPATH[:rehydrate], XPATHNS).each do |e|
      lang = e.xpath(XPATH[:lang]).to_s.strip
      # dt   = e['datatype'] # XXX no datatype rn
      text = (e['content'] || e.xpath('.//text()').to_a.join).strip

      # now we have the literal
      lit = [RDF::Literal(text)]
      lit.unshift RDF::Literal(text, language: lang) unless lang.empty?

      # candidates
      cand = {}
      lit.map do |t|
        graph.query(object: t).to_a
      end.flatten.each do |x|
        y = cand[x.subject] ||= {}
        (y[:stmts] ||= []) << x
        y[:types]  ||= graph.query([x.subject, RDF.type, nil]).objects.sort
      end

      # if there's only one candidate, this is basically a noop
      chosen = cand.keys.first if cand.size == 1

      # call the block to reconcile any gaps or conflicts
      if block_given? and cand.size != 1
        # the block is expected to return one of the candidates or
        # nil. we call the block with the graph so that the block can
        # manipulate its contents.
        chosen = block.call cand, graph
        raise ArgumentError, 'block must return nil or a term' unless
          chosen.nil? or chosen.is_a? RDF::Term
      end

      if chosen
        # we assume this has been retrieved from the graph
        cc = cand[chosen]
        unless cc
          cc = cand[chosen] = {}
          cc[:stmts] = graph.query([chosen, nil, lit.first]).to_a.sort
          cc[:types] = graph.query([chosen, RDF.type, nil]).objects.sort
          # if either of these are empty then the graph was not
          # appropriately populated
          raise 'Missing a statement relating #{chosen} to #{text}' if
            cc[:stmts].empty?
        end

        # we should actually probably move any prefix/vocab/xmlns
        # declarations from the inner node to the outer one (although
        # in practice this will be an unlikely configuration)
        pfx = get_prefixes e

        # here we have pretty much everything except for the prefixes
        # and wherever we want to actually link to.

        inner = e.dup
        spec  = { [inner] => :a, href: '' }
        # we should have types
        spec[:typeof] = abbreviate cc[:types], prefixes: pfx unless
          cc[:types].empty?

        markup replace: e, spec: spec
      end
    end
    # return maybe the elements that did/didn't get changed?
  end

  ######## RENDERING STUFF ########

  # Given a structure of the form +{ predicate => [objects] }+,
  # rearrange the structure into one more amenable to rendering
  # RDFa. Returns a hash of the form +{ resources: { r1 => Set[p1, pn]
  # }, literals: { l1 => Set[p2, pm] }, types: Set[t1, tn], datatypes:
  # Set[d1, dn] }+. This inverted structure can then be conveniently
  # traversed to generate the RDFa. An optional block lets us examine
  # the predicate-object pairs as they go by.
  #
  # @param struct [Hash] The struct of the designated form
  # @yield [p, o] An optional block is given the predicate-object pair
  # @return [Hash] The inverted structure, as described.
  #
  def prepare_collation struct, &block
    resources = {}
    literals  = {}
    datatypes = Set.new
    types     = Set.new

    struct.each do |p, v|
      v.each do |o|
        block.call p, o if block

        if o.literal?
          literals[o] ||= Set.new
          literals[o].add p
          # collect the datatype
          datatypes.add o.datatype if o.has_datatype?
        else
          if  p == RDF::RDFV.type
            # separate the type
            types.add o
          else
            # collect the resource
            resources[o] ||= Set.new
            resources[o].add p
          end
        end
      end
    end

    { resources: resources, literals: literals,
      datatypes: datatypes, types: types }
  end

  # Given a hash of prefixes and an array of nodes, obtain the the
  # subset of prefixes that abbreviate the nodes. Scans RDF URIs as
  # well as RDF::Literal datatypes.
  #
  # @param prefixes [#to_h] The prefixes, of the form +{ k: "v" }+
  # @param nodes [Array<RDF::Term>] The nodes to supply
  # @return [Hash] The prefix subset
  def prefix_subset prefixes, nodes
    prefixes = sanitize_prefixes prefixes, true

    raise 'nodes must be arrayable' unless nodes.respond_to? :to_a

    # sniff out all the URIs and datatypes
    resources = smush_struct nodes, uris: true

    # now we abbreviate all the resources
    pfx = abbreviate(resources.to_a,
      prefixes: prefixes, noop: false, sort: false).uniq.compact.map do |p|
      p.split(?:).first.to_sym
    end.uniq.to_set

    # now we return the subset 
    prefixes.select { |k, _| pfx.include? k.to_sym }
  end

  # turns any data structure into a set of nodes
  def smush_struct struct, uris: false
    out = Set.new

    if struct.is_a? RDF::Term
      if uris
        case
        when struct.literal?
          out << struct.datatype if struct.datatype?
        when struct.uri? then out << struct
        end
      else
        out << struct
      end
    elsif struct.respond_to? :to_a
      out |= struct.to_a.map do |s|
        smush_struct(s, uris: uris).to_a
      end.flatten.to_set
    end

    out
  end

  def invert_struct struct
    nodes = {}

    struct.each do |p, v|
      v.each do |o|
        nodes[o] ||= Set.new
        nodes[o] << p
      end
    end

    nodes
  end

  def title_tag predicates, content,
      prefixes: {}, vocab: nil, lang: nil, xhtml: true

    # begin with the tag
    tag = { '#title' => content.to_s,
      property: abbreviate(predicates, prefixes: prefixes, vocab: vocab) }

    # we set the language if it exists and is different from the
    # body OR if it is xsd:string we set it to the empty string
    lang = (content.language? && content.language != lang ?
      content.language : nil) || (content.datatype == RDF::XSD.string &&
      lang ? '' : nil)
    if lang
      tag['xml:lang'] = lang if xhtml
      tag[:lang] = lang
    end
    if content.datatype? && content.datatype != RDF::XSD.string
      tag[:datatype] = abbreviate(content.datatype,
        prefixes: prefixes, vocab: vocab)
    end

    tag
  end

  # Generate a tag in the XML::Mixup spec format that contains a
  # single literal. Defaults to `:span`.
  #
  # @param value [RDF::Term] the term to be represented
  # @param name  [Symbol, String] the element name
  # @param property [RDF::URI, Array] the value of the `property=` attribute
  # @param text [String] literal text (puts value in `content=`)
  # @param prefixes [Hash] prefixes we should know about for making CURIEs
  #
  # @return [Hash] the element spec
  #
  def literal_tag value, name: :span, property: nil, text: nil,
      prefixes: {}, vocab: nil
    # literal text content if different from the value
    content = if value.literal? and text and text != value.value
                value.value
              end

    out = { [text || value.value] => name }
    out[:content]  = content if content
    out[:property] =
      abbreviate(property, prefixes: prefixes, vocab: vocab) if property

    # almost certain this is true, but not completely
    if value.literal?
      out['xml:lang'] = value.language if value.language?
      out[:datatype]  =
        abbreviate(value.datatype, prefixes: prefixes, vocab: vocab) if
        value.datatype?
    end

    # note you can do surgery to this otherwise
    out
  end

  # Generate a tag in the XML::Mixup spec format that contains a
  # single text link. Defaults to `:a`. Provides the means to include
  # a label relation.
  #
  # @param target [RDF::URI]
  #
  # @return [Hash] the element spec
  #
  def link_tag target, rel: nil, rev: nil, href: nil, about: nil, typeof: nil,
      label: nil, property: nil, name: :a, placeholder: nil, base: nil,
      prefixes: nil, vocab: nil

    # * target is href= by default
    # * if we supply an href=, target becomes resource=
    if href
      resource = target
    else
      href = target
    end

    # make a relative uri but only if we have a base, otherwise don't bother
    if base
      href = href.is_a?(URI) ? href : URI(uri_pp href.to_s)
      base = base.is_a?(URI) ? base : URI(uri_pp base.to_s)
      href = base.route_to(href)
    end

    # construct the label tag/relation
    ltag = if property and label.is_a? RDF::Literal
             literal_tag label, property: property,
               prefixes: prefixes, vocab: vocab
            else
              [label.to_s]
            end

    # make the element with the bits we know for sure
    out = { ltag => name, href: href }

    # make the attributes
    { rel: rel, rev: rev, about: about,
     typeof: typeof, resource: resource }.each do |attr, term|
      out[attr] = abbreviate term, prefixes: prefixes, vocab: vocab if term
    end

    out
  end

  ######## MISC STUFF ########

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

      # keep this from tripping up
      next unless term.uri? and term.respond_to? :class?

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

  # duplicate instance methods as module methods
  extend self
end
