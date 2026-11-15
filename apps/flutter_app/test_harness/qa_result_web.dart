import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void writeQaResult(Map<String, Object?> value) {
  globalContext.setProperty('chtLargeQaResult'.toJS, value.jsify());
}
