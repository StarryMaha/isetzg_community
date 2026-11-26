allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Some Flutter plugins still hardcode an older compileSdk. AGP 9 rejects
    // their AAR metadata unless the build compiles against API 36+, so
    // normalise every Android subproject to the same compileSdk as the app.
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val methods = ext.javaClass.methods
            val setter = methods.firstOrNull {
                it.name == "setCompileSdk" && it.parameterTypes.size == 1
            } ?: methods.firstOrNull {
                it.name == "setCompileSdkVersion" && it.parameterTypes.size == 1
            }
            setter?.invoke(ext, 36)
        }
    }

    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
