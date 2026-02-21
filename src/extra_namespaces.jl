# Additional DefinedNamespace vocabulary constants

const FOAF = DefinedNamespace(
    "http://xmlns.com/foaf/0.1/",
    Set(["Person", "name", "mbox", "homepage", "knows", "Agent", "Group",
         "Organization", "Document", "Image", "nick", "title", "firstName",
         "lastName", "age", "gender", "interest", "based_near", "depiction",
         "depicts", "thumbnail", "workplaceHomepage", "schoolHomepage",
         "publications", "currentProject", "pastProject", "account",
         "OnlineAccount", "accountName", "accountServiceHomepage", "openid",
         "tipjar", "sha1", "made", "maker", "member", "membershipClass",
         "birthday", "status", "geekcode", "familyName", "givenName", "phone",
         "workInfoHomepage", "weblog", "logo", "topic", "topic_interest",
         "myersBriggs", "plan", "img", "isPrimaryTopicOf", "primaryTopic",
         "focus", "holdsAccount", "jabberID", "aimChatID", "icqChatID",
         "yahooChatID", "msnChatID", "skypeID", "page", "theme",
         "dnaChecksum"])
)

const DC = DefinedNamespace(
    "http://purl.org/dc/elements/1.1/",
    Set(["title", "creator", "subject", "description", "publisher",
         "contributor", "date", "type", "format", "identifier", "source",
         "language", "relation", "coverage", "rights"])
)

const DCTERMS = DefinedNamespace(
    "http://purl.org/dc/terms/",
    Set(["abstract", "accessRights", "accrualMethod", "accrualPeriodicity",
         "accrualPolicy", "alternative", "audience", "available",
         "bibliographicCitation", "conformsTo", "contributor", "coverage",
         "created", "creator", "date", "dateAccepted", "dateCopyrighted",
         "dateSubmitted", "description", "educationLevel", "extent", "format",
         "hasFormat", "hasPart", "hasVersion", "identifier",
         "instructionalMethod", "isFormatOf", "isPartOf", "isReferencedBy",
         "isReplacedBy", "isRequiredBy", "issued", "isVersionOf", "language",
         "license", "mediator", "medium", "modified", "provenance",
         "publisher", "references", "relation", "replaces", "requires",
         "rights", "rightsHolder", "source", "spatial", "subject",
         "tableOfContents", "temporal", "title", "type", "valid"])
)

const DCAT = DefinedNamespace(
    "http://www.w3.org/ns/dcat#",
    Set(["Catalog", "CatalogRecord", "Dataset", "Distribution", "DataService",
         "Resource", "dataset", "distribution", "downloadURL", "mediaType",
         "byteSize", "accessURL", "landingPage", "keyword", "theme",
         "contactPoint", "record", "service", "endpointURL",
         "endpointDescription", "servesDataset", "catalog", "inCatalog",
         "hadRole", "qualifiedRelation", "spatialResolutionInMeters",
         "temporalResolution", "accessService", "compressFormat",
         "packageFormat", "startDate", "endDate", "bbox", "centroid"])
)

const PROV = DefinedNamespace(
    "http://www.w3.org/ns/prov#",
    Set(["Entity", "Activity", "Agent", "wasGeneratedBy", "wasDerivedFrom",
         "wasAttributedTo", "startedAtTime", "used", "wasInformedBy",
         "endedAtTime", "wasAssociatedWith", "actedOnBehalfOf",
         "wasInfluencedBy", "alternateOf", "specializationOf",
         "generatedAtTime", "hadPrimarySource", "value",
         "qualifiedGeneration", "qualifiedDerivation", "qualifiedAttribution",
         "qualifiedAssociation", "qualifiedDelegation", "qualifiedInfluence",
         "qualifiedUsage", "hadActivity", "hadGeneration", "hadPlan",
         "hadUsage", "hadRole", "atTime", "atLocation", "hadMember",
         "Collection", "EmptyCollection", "Bundle", "SoftwareAgent", "Person",
         "Organization", "Location", "Influence", "Generation", "Usage",
         "Communication", "Start", "End", "Derivation", "Association",
         "Attribution", "Delegation", "Plan", "Revision", "Quotation",
         "PrimarySource"])
)

const SDO = DefinedNamespace(
    "https://schema.org/",
    Set(["Thing", "Action", "CreativeWork", "Event", "Intangible",
         "MedicalEntity", "Organization", "Person", "Place", "Product",
         "name", "description", "url", "image", "sameAs", "identifier",
         "email", "telephone", "address", "author", "dateCreated",
         "dateModified", "datePublished", "license", "version", "about",
         "text", "headline", "encodingFormat", "contentUrl", "thumbnailUrl",
         "duration", "startDate", "endDate", "location", "organizer",
         "performer", "attendee", "offers", "price", "priceCurrency",
         "availability", "sku", "brand", "color", "weight", "height",
         "width", "depth", "material"])
)

const SH = DefinedNamespace(
    "http://www.w3.org/ns/shacl#",
    Set(["Shape", "NodeShape", "PropertyShape", "property", "targetClass", "targetNode",
         "targetObjectsOf", "targetSubjectsOf", "path", "datatype",
         "minCount", "maxCount", "minExclusive", "minInclusive",
         "maxExclusive", "maxInclusive", "minLength", "maxLength", "pattern",
         "flags", "uniqueLang", "hasValue", "nodeKind", "BlankNode", "IRI",
         "BlankNodeOrIRI", "BlankNodeOrLiteral", "IRIOrLiteral", "Literal",
         "NodeKind", "severity", "message", "conforms", "result",
         "resultSeverity", "resultMessage", "focusNode", "resultPath",
         "value", "sourceShape", "sourceConstraintComponent", "Violation",
         "Warning", "Info", "ValidationReport", "ValidationResult",
         "shapesGraph"])
)

const VANN = DefinedNamespace(
    "http://purl.org/vocab/vann/",
    Set(["preferredNamespacePrefix", "preferredNamespaceUri", "usageNote",
         "changes", "example", "termGroup"])
)

const VOID = DefinedNamespace(
    "http://rdfs.org/ns/void#",
    Set(["Dataset", "Linkset", "dataDump", "sparqlEndpoint",
         "exampleResource", "vocabulary", "subset", "target",
         "subjectsTarget", "objectsTarget", "linkPredicate", "triples",
         "entities", "classes", "properties", "distinctSubjects",
         "distinctObjects", "documents", "uriSpace", "uriRegexPattern",
         "class", "property", "classPartition", "propertyPartition",
         "feature", "openSearchDescription", "rootResource", "inDataset"])
)

const DOAP = DefinedNamespace(
    "http://usefulinc.com/ns/doap#",
    Set(["Project", "Version", "Repository", "name", "homepage", "created",
         "shortdesc", "description", "release", "mailing_list", "category",
         "license", "repository", "anon_root", "browse", "module",
         "programming_language", "os", "download_page", "download_mirror",
         "revision", "file_release", "wiki", "bug_database", "screenshots",
         "old_homepage", "developer", "documenter", "maintainer", "tester",
         "helper", "translator", "implements", "service_endpoint", "language",
         "vendor", "platform"])
)

const ORG = DefinedNamespace(
    "http://www.w3.org/ns/org#",
    Set(["Organization", "FormalOrganization", "OrganizationalUnit",
         "OrganizationalCollaboration", "Site", "Membership", "Role", "Post",
         "ChangeEvent", "memberOf", "hasMember", "purpose", "classification",
         "hasSubOrganization", "subOrganizationOf", "hasSite", "siteOf",
         "basedAt", "member", "hasMembership", "organization", "role",
         "siteAddress", "headOf", "linkedTo", "originalOrganization",
         "changedBy", "resultedFrom", "resultingOrganization"])
)

const GEO = DefinedNamespace(
    "http://www.opengis.net/ont/geosparql#",
    Set(["Feature", "Geometry", "SpatialObject", "hasGeometry", "asWKT",
         "asGML", "sfWithin", "sfContains", "sfIntersects", "sfOverlaps",
         "sfTouches", "sfCrosses", "sfDisjoint", "sfEquals", "ehContains",
         "ehCoveredBy", "ehCovers", "ehDisjoint", "ehEquals", "ehInside",
         "ehMeet", "ehOverlap", "rcc8dc", "rcc8ec", "rcc8eq", "rcc8ntpp",
         "rcc8ntppi", "rcc8po", "rcc8tpp", "rcc8tppi",
         "hasSpatialResolution", "hasMetricSpatialResolution", "dimension",
         "coordinateDimension", "spatialDimension", "isEmpty", "isSimple",
         "hasSerialization"])
)
