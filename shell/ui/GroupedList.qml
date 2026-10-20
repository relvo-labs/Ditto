import QtQuick

/// #116: a group of ListRows in one card under a 13 px heading, with an
/// optional wrapped caption. Same API and fallback as Section (which it is);
/// without a candidate style it renders as the existing Section.
Section {
    carded: true
}
