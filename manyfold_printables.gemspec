require_relative "lib/manyfold_printables/version"

Gem::Specification.new do |spec|
  spec.name = "Manyfold Printables"
  spec.version = ManyfoldPrintables::VERSION
  spec.authors = ["nxn"]
  spec.email = ["nxn@localhost"]
  spec.homepage = "https://github.com/nxn/manyfold_printables"
  spec.summary = "Import models and creators from Printables.com via their GraphQL API"
  spec.description = "Adds Printables.com as an external site source for Manyfold. " \
                     "Paste a printables.com/model/ URL on import or attach it to an " \
                     "existing model and Manyfold will pull metadata, images and " \
                     "downloadable files (STLs, 3MFs, gcodes, images) from Printables' " \
                     "public GraphQL API (https://api.printables.com/graphql/). " \
                     "No API key is required."
  spec.license = "MIT"
  spec.metadata = {
    "manyfold_version" => ">= 0.146.0",
  }
end
