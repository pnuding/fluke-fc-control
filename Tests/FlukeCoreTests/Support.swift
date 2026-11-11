import Foundation

// The Command Line Tools' Swift Testing install ships no `_Testing_Foundation` overlay module, so a
// file that imports both Foundation and Testing fails to compile. Test files therefore don't import
// Foundation and use this alias.
typealias TestData = Data
