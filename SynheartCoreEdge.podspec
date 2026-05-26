Pod::Spec.new do |s|
  s.name         = "SynheartCoreEdge"
  s.version      = "0.0.4"
  s.summary      = "Lightweight Synheart Core SDK for watchOS / Apple Watch."
  s.description  = <<-DESC
    On-watch session engine + phone relay for the Synheart platform.
    Runs the on-device runtime locally (`computeLocal`) or streams raw
    biosignal samples to a paired iPhone (`stream`). Pair with a
    `BiosignalProvider` of your choice (HealthKit, BLE HRM, custom).
  DESC
  s.homepage     = "https://github.com/synheart-ai/synheart-core-swift-edge"
  s.license      = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author       = { "Synheart" => "dev@synheart.ai" }
  s.source       = {
    :git => "https://github.com/synheart-ai/synheart-core-swift-edge.git",
    :tag => "v#{s.version}"
  }

  s.ios.deployment_target     = "15.0"
  s.osx.deployment_target     = "13.0"
  s.watchos.deployment_target = "9.0"

  s.swift_versions = ["5.9"]
  s.source_files   = "Sources/SynheartCoreEdge/**/*.swift"

  s.dependency "SynheartSession", "~> 0.2.1"
end
