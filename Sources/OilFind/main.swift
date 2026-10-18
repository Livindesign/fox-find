import OilFindApp
import LocalFindContent
#if DEBUG
// The isolated workflow preview must not open the real content databases or models.
if Application.isWorkflowPreview { Application.run() }
else { Application.run(appExtension: LocalFindExtension()) }
#else
Application.run(appExtension: LocalFindExtension())
#endif
