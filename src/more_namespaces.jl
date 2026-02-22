# Additional predefined namespaces matching Python rdflib

const BRICK = Namespace("https://brickschema.org/schema/Brick#")

const CSVW = Namespace("http://www.w3.org/ns/csvw#")

const DCAM = DefinedNamespace(
    "http://purl.org/dc/dcam/",
    Set(["VocabularyEncodingScheme", "domainIncludes", "memberOf", "rangeIncludes"])
)

const DCMITYPE = DefinedNamespace(
    "http://purl.org/dc/dcmitype/",
    Set(["Collection", "Dataset", "Event", "Image", "InteractiveResource",
         "MovingImage", "PhysicalObject", "Service", "Software", "Sound",
         "StillImage", "Text"])
)

const ODRL2 = Namespace("http://www.w3.org/ns/odrl/2/")

const PROF = DefinedNamespace(
    "http://www.w3.org/ns/dx/prof/",
    Set(["Profile", "ResourceDescriptor", "ResourceRole",
         "hasArtifact", "hasResource", "hasRole", "hasToken",
         "isInheritedFrom", "isProfileOf", "isTransitiveProfileOf"])
)

const QB = DefinedNamespace(
    "http://purl.org/linked-data/cube#",
    Set(["Attachable", "AttributeProperty", "CodedProperty", "ComponentProperty",
         "ComponentSet", "ComponentSpecification", "DataSet", "DataStructureDefinition",
         "DimensionProperty", "HierarchicalCodeList", "MeasureProperty",
         "Observation", "ObservationGroup", "Slice", "SliceKey",
         "attribute", "codeList", "component", "componentAttachment",
         "componentProperty", "componentRequired", "concept", "dataSet",
         "dimension", "hierarchyRoot", "measure", "measureDimension",
         "measureType", "observation", "observationGroup", "order",
         "parentChildProperty", "slice", "sliceKey", "sliceStructure", "structure"])
)

const SOSA = Namespace("http://www.w3.org/ns/sosa/")

const SSN = DefinedNamespace(
    "http://www.w3.org/ns/ssn/",
    Set(["Deployment", "Input", "Output", "Property", "Stimulus", "System",
         "deployedOnPlatform", "deployedSystem", "detects", "forProperty",
         "hasDeployment", "hasInput", "hasOutput", "hasProperty", "hasSubSystem",
         "implementedBy", "implements", "inDeployment", "isPropertyOf",
         "isProxyFor", "wasOriginatedBy"])
)

const TIME = Namespace("http://www.w3.org/2006/time#")

const WGS = DefinedNamespace(
    "https://www.w3.org/2003/01/geo/wgs84_pos#",
    Set(["Point", "SpatialThing", "alt", "lat", "lat_long", "location", "long"])
)
