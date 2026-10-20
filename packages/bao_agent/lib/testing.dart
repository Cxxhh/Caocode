/// Stand-ins for the model under test: a scripted [FakeModel] for an
/// engine in the same isolate, and [FakeApi], the Messages API on this
/// machine for one that reaches it over HTTP (an isolate's, the app's).
library;

export 'src/testing/fake_api.dart';
export 'src/testing/fake_model.dart';
