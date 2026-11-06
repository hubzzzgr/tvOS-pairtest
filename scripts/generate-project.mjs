import fs from 'node:fs';
import crypto from 'node:crypto';
const id = name => crypto.createHash('sha1').update(name).digest('hex').slice(0, 24).toUpperCase();
const quote = value => JSON.stringify(value);
const objects = [];
const add = (name, content) => { objects.push(`${id(name)} = { ${content} };`); return id(name); };
const files = fs.readdirSync('TVPair/App').map(x => `TVPair/App/${x}`).concat(fs.readdirSync('TVPair/Views').map(x => `TVPair/Views/${x}`)).filter(x => x.endsWith('.swift')).sort();
const refs = files.map(file => add(file, `isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${quote(file)}; sourceTree = "<group>";`));
const builds = files.map(file => add(`build:${file}`, `isa = PBXBuildFile; fileRef = ${id(file)};`));
const info = add('info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = TVPair/Resources/Info.plist; sourceTree = "<group>";');
const notices = ['LICENSE', 'THIRD_PARTY_NOTICES.md'];
const noticeRefs = notices.map(file => add(file, `isa = PBXFileReference; lastKnownFileType = text; path = ${quote(file)}; sourceTree = "<group>";`));
const noticeBuilds = notices.map(file => add(`build:${file}`, `isa = PBXBuildFile; fileRef = ${id(file)};`));
const product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TVPair.app; sourceTree = BUILT_PRODUCTS_DIR;');
const products = add('products', `isa = PBXGroup; children = (${product},); name = Products; sourceTree = "<group>";`);
const group = add('group', `isa = PBXGroup; children = (${refs.join(',')},${noticeRefs.join(',')},${info},${products},); sourceTree = "<group>";`);
const packageRef = add('package', 'isa = XCLocalSwiftPackageReference; relativePath = Packages/TVPairCore;');
const dependency = add('dependency', `isa = XCSwiftPackageProductDependency; package = ${packageRef}; productName = TVPairCore;`);
const frameworkBuild = add('framework-build', `isa = PBXBuildFile; productRef = ${dependency};`);
const sources = add('sources', `isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (${builds.join(',')},); runOnlyForDeploymentPostprocessing = 0;`);
const frameworks = add('frameworks', `isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (${frameworkBuild},); runOnlyForDeploymentPostprocessing = 0;`);
const resources = add('resources', `isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (${noticeBuilds.join(',')},); runOnlyForDeploymentPostprocessing = 0;`);
for (const level of ['project', 'target']) {
  for (const config of ['Debug', 'Release']) {
    const settings = level === 'project'
      ? `CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_OPTIMIZATION_LEVEL = ${quote(config === 'Debug' ? '-Onone' : '-O')}; DEBUG_INFORMATION_FORMAT = ${quote(config === 'Debug' ? 'dwarf' : 'dwarf-with-dsym')}; SWIFT_ACTIVE_COMPILATION_CONDITIONS = ${quote(config === 'Debug' ? 'DEBUG' : '')};`
      : `PRODUCT_BUNDLE_IDENTIFIER = org.tvpair.pairtest; PRODUCT_NAME = TVPair; INFOPLIST_FILE = TVPair/Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = NO; CODE_SIGN_STYLE = Automatic; MARKETING_VERSION = 1.0; CURRENT_PROJECT_VERSION = 1; ENABLE_PREVIEWS = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";`;
    add(`${level}:${config}`, `isa = XCBuildConfiguration; name = ${config}; buildSettings = { ${settings} };`);
  }
  add(`${level}:configs`, `isa = XCConfigurationList; buildConfigurations = (${id(`${level}:Debug`)},${id(`${level}:Release`)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;`);
}
const target = add('target', `isa = PBXNativeTarget; buildConfigurationList = ${id('target:configs')}; buildPhases = (${sources},${frameworks},${resources},); buildRules = (); dependencies = (); name = TVPair; packageProductDependencies = (${dependency},); productName = TVPair; productReference = ${product}; productType = "com.apple.product-type.application";`);
const project = add('project', `isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }; buildConfigurationList = ${id('project:configs')}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = ${group}; packageReferences = (${packageRef},); productRefGroup = ${products}; projectDirPath = ""; projectRoot = ""; targets = (${target},);`);
fs.mkdirSync('TVPair.xcodeproj/xcshareddata/xcschemes', { recursive: true });
fs.writeFileSync('TVPair.xcodeproj/project.pbxproj', `// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n${objects.join('\n')}\n}; rootObject = ${project}; }\n`);
fs.writeFileSync('TVPair.xcodeproj/xcshareddata/xcschemes/TVPair.xcscheme', `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="TVPair.app" BlueprintName="TVPair" ReferencedContainer="container:TVPair.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="TVPair.app" BlueprintName="TVPair" ReferencedContainer="container:TVPair.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n`);
console.log(`Generated TVPair.xcodeproj with ${files.length} app source files.`);
