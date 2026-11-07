import QtQml

// Non-visual container: a Window declared inside an Item is embedded (Qt >= 6.7)
// and never shows when that Item has no window, so window hosts use this root.
QtObject {
  default property list<QtObject> resources
}
