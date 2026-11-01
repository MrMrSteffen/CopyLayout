// Copy Layout Breaks from Current Part
// Requires MuseScore Studio 4.4 or later.
//
// Open the part whose layout you like, run the plugin, tick the target part/s,
// press "Copy". Page breaks, system breaks and "keep measures on the same system"
// are copied measure by measure. Section breaks are never touched (they are shared
// between score and parts anyway). One Ctrl+Z undoes the whole operation.
//
// The UI uses only plain QtQuick items (no QtQuick.Controls).

import QtQuick 2.0
import MuseScore 3.0

MuseScore {
    id: plugin
    menuPath: "Plugins.Copy Layout Breaks from Current Part"
    title: "Copy Layout Breaks from Current Part"
    description: "Copies page, system and keep-together breaks from the currently open part to one or more other parts."
    version: "2.1"
    categoryCode: "composing-arranging-tools"
    requiresScore: true
    pluginType: "dialog"
    width: 380
    height: 540

    property var sourceScore: null
    property string sourceName: "(none)"
    property bool sourceIsMain: false
    property string status: ""

    ListModel { id: partModel }   // roles: title, idx, checked
    ListModel {
        id: optModel
        ListElement { key: "page";    label: "Page breaks";                            checked: true }
        ListElement { key: "line";    label: "System breaks";                          checked: true }
        ListElement { key: "nobreak"; label: "Keep measures on same system";           checked: true }
        ListElement { key: "replace"; label: "Remove existing breaks in target first"; checked: true }
    }

    onRun: init()

    // ---------------------------------------------------------------- setup

    function init() {
        partModel.clear();
        status = "";
        if (!curScore) {
            status = "No score open.";
            return;
        }
        var ex = curScore.excerpts;
        if (!ex || ex.length === 0) {
            status = "This score has no parts (open each part once so MuseScore creates it).";
            return;
        }
        sourceScore = curScore;
        sourceName = "Full score";
        sourceIsMain = true;
        for (var i = 0; i < ex.length; i++) {
            if (ex[i].partScore && ex[i].partScore.is(curScore)) {
                sourceName = ex[i].title;
                sourceIsMain = false;
            } else {
                partModel.append({ title: ex[i].title, idx: i, checked: false });
            }
        }
        console.log("CopyLayout: source =", sourceName, ", targets available =", partModel.count);
        if (sourceIsMain)
            status = "Note: the full score is open, not a part. Page breaks will be copied as system breaks.";
    }

    function opt(key) {
        for (var i = 0; i < optModel.count; i++)
            if (optModel.get(i).key === key) return optModel.get(i).checked;
        return false;
    }

    function buttonClicked(name) {
        var i;
        if (name === "All")
            for (i = 0; i < partModel.count; i++) partModel.setProperty(i, "checked", true);
        else if (name === "None")
            for (i = 0; i < partModel.count; i++) partModel.setProperty(i, "checked", false);
        else if (name === "Copy")
            apply();
        else if (name === "Close")
            quit();
    }

    //  helper functions

    function hasType(types, t) {
        for (var i = 0; i < types.length; i++)
            if (types[i] == t) return true;
        return false;
    }

    function measureHasBreak(m, t) {
        var els = m.elements;
        for (var i = 0; i < els.length; i++)
            if (els[i].type == Element.LAYOUT_BREAK && els[i].layoutBreakType == t)
                return true;
        return false;
    }

    function measureList(score) {
        var list = [];
        for (var m = score.firstMeasure; m; m = m.nextMeasure)
            list.push(m);
        return list;
    }

    function indexOfMeasure(list, m) {
        for (var i = 0; i < list.length; i++)
            if (list[i].is(m)) return i;
        return -1;
    }

    // Returns for the source score.
    function collectBreaks(score, convertPageToLine) {
        var list = measureList(score);
        var result = {};

        function visit(m) {
            var els = m.elements;
            for (var k = 0; k < els.length; k++) {
                var e = els[k];
                if (e.type != Element.LAYOUT_BREAK) continue;
                var t = e.layoutBreakType;
                if (t == LayoutBreak.SECTION) continue;
                if (convertPageToLine && t == LayoutBreak.PAGE) t = LayoutBreak.LINE;

                var idx = indexOfMeasure(list, m);
                if (idx < 0) {
                    // multimeasure rest: the break belongs to the last measure it covers
                    var nxt = m.nextMeasure;
                    idx = nxt ? indexOfMeasure(list, nxt) - 1 : list.length - 1;
                }
                if (idx < 0) continue;
                if (!result[idx]) result[idx] = [];
                if (!hasType(result[idx], t)) result[idx].push(t);
            }
        }

        for (var m = score.firstMeasure; m; m = m.nextMeasure) visit(m);
        for (var mm = score.firstMeasureMM; mm; mm = mm.nextMeasureMM) visit(mm);
        return result;
    }

    function removeBreaks(part, types) {
        var found = [];
        for (var m = part.firstMeasure; m; m = m.nextMeasure) {
            var els = m.elements;
            for (var k = 0; k < els.length; k++) {
                var e = els[k];
                if (e.type == Element.LAYOUT_BREAK && hasType(types, e.layoutBreakType))
                    found.push(e);
            }
        }
        for (var i = 0; i < found.length; i++)
            removeElement(found[i]);
        return found.length;
    }

    function addBreaks(part, src, types) {
        var templates = {};
        for (var i = 0; i < types.length; i++) {
            var b = newElement(Element.LAYOUT_BREAK);
            b.layoutBreakType = types[i];
            b.score = part;
            templates[types[i]] = b;
        }

        var cursor = part.newCursor();
        cursor.rewind(Cursor.SCORE_START);
        var idx = 0;
        var n = 0;
        do {
            var wanted = src[idx];
            if (wanted) {
                for (var j = 0; j < wanted.length; j++) {
                    var t = wanted[j];
                    if (!hasType(types, t)) continue;
                    if (measureHasBreak(cursor.measure, t)) continue;
                    cursor.add(templates[t].clone());
                    n++;
                }
            }
            idx++;
        } while (cursor.nextMeasure());
        return n;
    }

    //

    function apply() {
        if (!sourceScore) {
            status = "No source score.";
            return;
        }

        var targets = [];
        for (var i = 0; i < partModel.count; i++)
            if (partModel.get(i).checked) targets.push({ title: partModel.get(i).title, idx: partModel.get(i).idx });
        if (targets.length === 0) {
            status = "Select at least one target part.";
            return;
        }

        var types = [];
        if (opt("page"))    types.push(LayoutBreak.PAGE);
        if (opt("line"))    types.push(LayoutBreak.LINE);
        if (opt("nobreak")) types.push(LayoutBreak.NOBREAK);
        if (types.length === 0) {
            status = "Select at least one break type.";
            return;
        }
        var replace = opt("replace");

        var src = collectBreaks(sourceScore, sourceIsMain);
        var ex = curScore.excerpts;
        var removed = 0, added = 0, names = [];

        curScore.startCmd();
        for (var t = 0; t < targets.length; t++) {
            var part = ex[targets[t].idx] ? ex[targets[t].idx].partScore : null;
            if (!part) continue;
            if (replace) removed += removeBreaks(part, types);
            added += addBreaks(part, src, types);
            names.push(targets[t].title);
        }
        curScore.endCmd();

        status = "Copied from \"" + sourceName + "\" to: " + names.join(", ")
               + "\nAdded " + added + " break(s)"
               + (replace ? ", removed " + removed + " old break(s)." : ".");
        console.log("CopyLayout:", status);
    }

    // ------------------------------------------------------------------- UI
    // Plain QtQuick

    Rectangle {
        anchors.fill: parent
        color: "#f2f2f2"

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            Text {
                width: parent.width
                wrapMode: Text.Wrap
                font.bold: true
                font.pixelSize: 14
                color: "#111111"
                text: "Source (open part): " + plugin.sourceName
            }

            Text { text: "Copy layout to:"; font.pixelSize: 13; color: "#111111" }

            // part list
            Rectangle {
                width: parent.width
                height: 180
                color: "#ffffff"
                border.color: "#a0a0a0"

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 6
                    clip: true
                    contentHeight: partCol.height

                    Column {
                        id: partCol
                        width: parent.width

                        Repeater {
                            model: partModel
                            delegate: Item {
                                width: partCol.width
                                height: 26
                                Rectangle {
                                    id: pbox
                                    width: 16; height: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                    border.color: "#555555"
                                    color: model.checked ? "#2b6cb0" : "#ffffff"
                                    Text {
                                        anchors.centerIn: parent
                                        text: model.checked ? "\u2713" : ""
                                        color: "#ffffff"
                                        font.pixelSize: 12
                                    }
                                }
                                Text {
                                    anchors.left: pbox.right
                                    anchors.leftMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: model.title
                                    font.pixelSize: 13
                                    color: "#111111"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: partModel.setProperty(index, "checked", !model.checked)
                                }
                            }
                        }
                    }
                }
            }

            // All / None
            Row {
                spacing: 6
                Repeater {
                    model: ["All", "None"]
                    delegate: Rectangle {
                        width: 70; height: 26; radius: 3
                        color: ma1.pressed ? "#c8c8c8" : "#e2e2e2"
                        border.color: "#999999"
                        Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 13; color: "#111111" }
                        MouseArea { id: ma1; anchors.fill: parent; onClicked: plugin.buttonClicked(modelData) }
                    }
                }
            }

            // options
            Column {
                width: parent.width
                Repeater {
                    model: optModel
                    delegate: Item {
                        width: parent.width
                        height: 26
                        Rectangle {
                            id: obox
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            border.color: "#555555"
                            color: model.checked ? "#2b6cb0" : "#ffffff"
                            Text {
                                anchors.centerIn: parent
                                text: model.checked ? "\u2713" : ""
                                color: "#ffffff"
                                font.pixelSize: 12
                            }
                        }
                        Text {
                            anchors.left: obox.right
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: model.label
                            font.pixelSize: 13
                            color: "#111111"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: optModel.setProperty(index, "checked", !model.checked)
                        }
                    }
                }
            }

            // Copy / Close
            Row {
                spacing: 6
                Repeater {
                    model: ["Copy", "Close"]
                    delegate: Rectangle {
                        width: 90; height: 30; radius: 3
                        color: ma2.pressed ? "#c8c8c8" : (modelData === "Copy" ? "#cfe0f5" : "#e2e2e2")
                        border.color: "#999999"
                        Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 13; font.bold: modelData === "Copy"; color: "#111111" }
                        MouseArea { id: ma2; anchors.fill: parent; onClicked: plugin.buttonClicked(modelData) }
                    }
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.Wrap
                font.pixelSize: 12
                color: "#333333"
                text: plugin.status
            }
        }
    }
}
