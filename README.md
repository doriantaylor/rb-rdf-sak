# RDF::SAK — Swiss Army Knife for RDF(a) Content

This library can be understood as something of a workbench for a Web
content management strategy that makes extensive use of _Linked
Data_. The goals of the system are as follows:

* Durable addresses with fine-grained addressability of content,
* Adherence to declarative data mediated by open standards,
* Easy content re-use, i.e., _transclusion_,
* Rich embedded metadata for search, social media, and other purposes.

`RDF::SAK` is also intended to serve as a substrate for:

* The maturation of a [content inventory
  ontology](https://privatealpha.com/ontology/content-inventory/1#),
* The use of semantic metadata [for manipulating content
  presentation](https://github.com/doriantaylor/rdfa-xslt),
* Development of a deterministic, standards-compliant, [client-side
  transclusion mechanism](https://github.com/doriantaylor/xslt-transclusion).
 
Finally, this library is also intended to establish a set of hard
requirements for the kind of RDF and Linked Data infrastructure that
would be necessary to replicate its behaviour in a more comprehensive
content management system.

The only public website currently generated by `RDF::SAK` is [my own
personal site](https://doriantaylor.com/), which I use as a test
corpus. However, this library draws together a number of techniques
which have been in use with employers and clients for well over a decade.

## How it Works

Because the focus of `RDF::SAK` is a corpus of interrelated Web
resources marked up just so, rather than presenting as an on-line Web
application, it instead both consumes and emits a set of static
files. It currently expects a directory of (X)HTML and/or Markdown as
its document source, along with one or more serialized RDF graphs
which house the metadata.

### Inputs

The files in the source tree can be named in any way, however, in the
metadata, they are expected to be primarily associated with UUIDs,
like the following (complete) entry:

```turtle
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
@prefix xhv:  <http://www.w3.org/1999/xhtml/vocab#> .
@prefix dct:  <http://purl.org/dc/terms/> .
@prefix foaf: <http://xmlns.com/foaf/0.1/> .
@prefix bibo: <http://purl.org/ontology/bibo/> .
@prefix ci:   <https://privatealpha.com/ontology/content-inventory/1#> .

<urn:uuid:b5c16511-6904-4130-b4e4-dd553f31bdd8>
    dct:abstract "Yet another slapdash about-me page." ;
    dct:created "2019-03-11T08:14:10+00:00"^^xsd:dateTime ;
    dct:creator <urn:uuid:ca637d4b-c11b-4152-be98-bde602e7abd4> ;
    dct:hasPart <https://www.youtube.com/embed/eV84dXJUvY8> ;
    dct:modified "2019-05-17T05:08:42+00:00"^^xsd:dateTime,
        "2019-05-17T18:37:37+00:00"^^xsd:dateTime ;
    dct:references <urn:uuid:01a1ad7d-8af0-4ad7-a8ec-ffaaa06bb6f1>,
        <urn:uuid:0d97c820-8929-42a1-8aca-f9e165d8085e>,
        <urn:uuid:1ae2942f-4ba6-4552-818d-0e6b91a4abee>,
        <urn:uuid:97bd312d-267d-433b-afc7-c0e9ab3311ed>,
        <urn:uuid:99cc7d73-4779-4a7c-82de-b9f08af85cf8>,
        <urn:uuid:a03bf9b5-56e6-42c7-bcd9-37ea6ad6a3d1>,
        <urn:uuid:afe5a68a-a224-4be9-9fec-071ab55aa70d>,
        <urn:uuid:d74d7e24-a6d6-4f49-94e8-e905d317c988>,
        <urn:uuid:ef4587cd-d8c6-4b3d-aa01-d07ab49eda4f> ;
    dct:replaces <urn:uuid:1944f86f-cafb-42f7-bca3-ad518f9b6ec7>,
        <urn:uuid:d30a49d7-71ed-4355-bc44-4bbe3d90e000> ;
    dct:title "Hello, Internet" ;
    bibo:status bs:published ;
    a bibo:Note ;
    xhv:alternate <urn:uuid:4a13ab5a-67a5-4e1a-970f-3425df7035bb>,
        <urn:uuid:c2f57107-9f79-4f13-a83c-4c73448c1c0b> ;
    xhv:bookmark <urn:uuid:c2f57107-9f79-4f13-a83c-4c73448c1c0b> ;
    xhv:index <urn:uuid:4a13ab5a-67a5-4e1a-970f-3425df7035bb> ;
    xhv:meta <urn:uuid:47d52b80-50df-4ac4-a3f3-941c95c1aa14> ;
    owl:sameAs <https://doriantaylor.com/breaking-my-silence-on-twitter>,
        <https://doriantaylor.com/person/dorian-taylor>,
        <https://doriantaylor.com/what-i-do>,
        <https://doriantaylor.com/what-i-do-for-money> ;
    foaf:depiction <https://doriantaylor.com/file/form-content-masked;desaturate;scale=800,700> ;
    ci:canonical <https://doriantaylor.com/hello-internet> ;
    ci:canonical-slug "hello-internet"^^xsd:token ;
    ci:indexed false .
```

> Another program generates these entries from version-controlled
> source trees. It was written over a decade ago in Python, intended
> to handle the Mercurial version control system. Eventually it will
> be switched to Git, rewritten in Ruby, and made part of `RDF::SAK`.

### Outputs

The library has methods to generate the following kinds of file:

* (X)HTML documents, where file inputs are married with metadata
* Special indexes, generated completely from metadata
* Atom feeds, with various partitioning criteria
* Google site maps,
* Apache rewrite maps.

All files are generated in the target directory as their canonical
UUID and a representative extension,
e.g. `b5c16511-6904-4130-b4e4-dd553f31bdd8.xml`. Human-readable URIs
are then overlaid onto these canonical addresses using rewrite
maps. This enables the system to retain a memory of address-to-UUID
assignments over time, with the eventual goal to eliminate 404 errors.

Documents themselves are traversed and embedded with metadata.
Wherever possible, links are given titles and semantic relations, and
a list of backlinks from all other resources is constructed. There are
modules for generating various elements in the `<head>` to accommodate
the various search and social media platforms. The strategy is to hold
the master data in the most appropriate RDF vocabularies, and then
subsequently map those properties to their proprietary counterparts,
e.g., Facebook OGP, Schema.org (Google), and Twitter Cards.

> The latter representations tend to cut corners with various
> datatypes and properties; it's much easier to go from strict RDF to
> a platform-specific schema than it is to go the other way around.

#### Private content

While a fine-grained access control subsystem is decidedly out of
scope, `RDF::SAK` has a rudimentary concept of _private_ resources. A
resource is assumed to be "private" unless its `bibo:status` is set to
`bibo:status/published`. A document may therefore have both a public
and private version, as the private version may have links to and from
other documents which themselves are not published. Links to private
documents get pruned from published ones, so as not to leak their
existence.

### Running

I endeavour to create a command-line interface but the _library_
interface is currently not stable enough to warrant it. The best way
to use `RDF::SAK` for now is within an interactive `pry` session:

```bash
~$ cd rdf-sak
~/rdf-sak$ pry -Ilib
[1] pry(main)> require 'rdf/sak'
=> true
[2] pry(main)> ctx = RDF::SAK::Context.new config: '~/my.conf'
=> <RDF::SAK::Context ...>
[3] pry(main)> doc = ctx.visit 'some-uri'
=> <RDF::SAK::Context::Document ...>
[4] pry(main)> doc.write_to_target
```

A YAML configuration file can be supplied in lieu of individual
parameters to the constructor:

```yaml
base: https://doriantaylor.com/
graph: # RDF graphs
  - ~/projects/active/doriantaylor.com/content-inventory.ttl
  - ~/projects/active/doriantaylor.com/concept-scheme.ttl
source: ~/projects/active/doriantaylor.com/source
target: ~/projects/active/doriantaylor.com/target
private: .private     # private content, relative to target
transform: /transform # XSLT stylesheet attached to all documents
```

### Deployment

Deploying the content can be done with `rsync`, although it requires
certain configuration changes on the server in order to work properly.

In Apache in particular, rewrite maps need to be defined in the main
server configuration:

```apache
# one need not place these in the document root but it's handy for rsync
RewriteEngine On
RewriteMap rewrite  ${DOCUMENT_ROOT}/.rewrite.map
RewriteMap redirect ${DOCUMENT_ROOT}/.redirect.map
RewriteMap gone     ${DOCUMENT_ROOT}/.gone.map

# then we just add something like this to prevent access to them
<Files ".*.map">
Require all denied
</Files>
```

The rest of the configuration can go in an `.htaccess`:

```apache
# this redirects to canonical slugs
RewriteCond "%{ENV:REDIRECT_SCRIPT_URL}" ^$
RewriteCond %{REQUEST_URI} "^/*(.*?)(\.xml)?$"
RewriteCond ${redirect:%1} ^.+$
RewriteRule ^/*(.*?)(\.xml)?$ ${redirect:$1} [L,NS,R=308]

# this takes care of terminated URIs
RewriteCond %{REQUEST_URI} ^/*(.*?)(\..+?)?$
RewriteCond ${gone:%1} ^.+$
RewriteRule .* - [L,NS,G]

# this internally rewrites slugs to UUIDs
RewriteCond "%{ENV:REDIRECT_SCRIPT_URL}" ^$
RewriteCond %{REQUEST_URI} ^/*(.*?)(\..+?)?$
RewriteCond ${rewrite:%1} ^.+$
RewriteRule ^/*(.*?)(\..+?)?$ /${rewrite:$1} [NS,PT]

# we can do something perhaps more elaborate to route private content
SetEnvIf Remote_Addr "31\.3\.3\.7" PRIVATE

# this splices in the private content if it is present
RewriteCond %{ENV:PRIVATE} !^$
RewriteCond %{DOCUMENT_ROOT}/.private%{REQUEST_URI} -F
RewriteRule ^/*(.*) /.private/$1 [NS,PT]
```

Configurations for other platforms can be figured out on request.

## Documentation

API documentation, for what it's worth at the moment, can be found [in
the usual place](https://rubydoc.info/github/doriantaylor/rb-rdf-sak/master).

## Installation

For now I recommend just running the library out of its source tree:

    git clone git@github.com/doriantaylor/rb-rdf-sak.git

## Contributing

Bug reports and pull requests are welcome at
[the GitHub repository](https://github.com/doriantaylor/rb-rdf-sak).

## Copyright & License

©2018 [Dorian Taylor](https://doriantaylor.com/)

This software is provided under
the [Apache License, 2.0](https://www.apache.org/licenses/LICENSE-2.0).
