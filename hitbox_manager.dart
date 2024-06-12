// Author:  Matthew Williams
// Date:    Spring 2024
// 
// This class provides methods to work with Verovio SVGs more in-depth than is
// supported from the library.  Initiate the internal representation with the
// initHitboxes method, and then query that data with these methods:
//   - getElementGroupBounds
//   - getElementId
//   - getElementGroupId
//   - getAllChildrenAtGroupPos
// 
// Few things to know about this class:
//  - "Accid" means accidental (sharp or flat sign)
//  - "Dir" means directive (plain text telling the player what to do or how to do it)
//  - "Hair Pin" is the alligator mouth that tells you to slowly start playing louder/softer
//  - When using any numbering system, the general rule is that 10 units = 1px.
//    - So a box of size 1000x1000 is actually 100px square
//  - In timed tests, initHitboxes completes in about 40ms for a 1-page test score

// ignore_for_file: non_constant_identifier_names, avoid_print, constant_identifier_names

import 'dart:math';

import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';


class HitboxManager {
  
  // Constants to use in syntax-critical strings to avoid run-time
  //  typo problems
  static const String 
      _ACCID = "accid",
      _BARLINE = "barLine",
      _BEAM = "beam",
      _CHORD = "chord",
      _CLASS = "class",
      _CLEF = "clef",
      _D = "d",
      _DEFS = "defs",
      _DIR = "dir",
      _DYNAM = "dynam",
      _G = "g",
      _HAIRPIN = "hairpin",
      _HEIGHT = "height",
      _ID = "id",
      _KEYACCID = "keyAccid",
      _KEYSIG = "keySig",
      _LAYER = "layer",
      _MEASURE = "measure",
      _METERSIG = "meterSig",
      _MREST = "mRest",
      _NOTE = "note",
      _PAGE_MARGIN = "page-margin", 
      _PATH = "path",
      _POINTS = "points",
      _REST = "rest",
      _SLUR = "slur",
      _SPACE = "space",
      _STAFF = "staff",
      _STEM = "stem",
      _SVG = "svg",
      _SYMBOL = "symbol",
      _SYSTEM = "system",
      _TIE = "tie",
      _TRANSFORM = "transform",
      _USE = "use",
      _VIEWBOX = "viewBox",
      _WIDTH = "width",
      _X = "x", _Y = "y",
      _XLINKHREF = "xlink:href";
  
  static const List<String> 
      ElementsToIgnoreDuringUnpacking = [_STEM, _SPACE],
      ElementsToUnpackFurther = [_BEAM, _CHORD, _LAYER, _KEYSIG],
      ElementsWhoseIDToIgnore = [_BEAM, _LAYER],
      XmlElementsToGrabFromStaff = [_LAYER, _KEYSIG, _CLEF, _METERSIG],
      SpecialRectsToGrabFromMeasure = [_DYNAM, _SLUR, _DIR, _HAIRPIN, _TIE];
  
  static const int ASSUMED_SYMBOL_VIEWPORT_SIZE = 1000;
  
  static const int LowestStaffHitboxMargin = 40;
  static const int KeyAccidExtraWidth = 80;
  
  String currentHitboxSvg = "";
  
  // When representing a hitbox, 7 numbers are used.
  //  0  1    2      3       4    5      6
  // [X, Y, Width, Height, Layer, id, groupID]
  
  Map<String, List<int>> symbolBounds = {};

  List<int> rowMarkers = [];
  List<List<int>> floatingRects = [];
  List<String> floatingRectDesc = [];
  List<List< int >> columnMarkers = [];
  List<List< String >> elementGroupIDs = [];
  List<List< List<List<int>> >> elementHitboxes = [];
  List<List< List<String> >> elementIDs = [];
  
  int pageHeight = -1;
  int pageWidth = -1;
  int pageOffsetX = 0;
  int pageOffsetY = 0;
  
  HitboxManager();
  
  int getRowIndex(int y) {
    for (int r = 0; r < rowMarkers.length; r++) {
      if (rowMarkers[r] >= y) return r-1;
    }
    return -1;
  }
  
  int getColIndex(int rowIndex, int x) {
    if (rowIndex == -1) return -1;
    for (int c = 0; c < columnMarkers[rowIndex].length; c++) {
      if (columnMarkers[rowIndex][c] >= x) return c-1;
    }
    return -1;
  }
  
  List<int> getElementGroupBounds(int x, int y) {
    int r = getRowIndex(y);
    int c = getColIndex(r, x);
    
    int top = rowMarkers[r];
    int height = rowMarkers[r+1] - top;
    int left = columnMarkers[r][c];
    int width = columnMarkers[r][c+1] - left;
    
    return [left, top, width, height];
  }
  
  /// Returns "" when none found
  String getElementId(int x, int y) {
    int r = getRowIndex(y);
    int c = getColIndex(r, x);
    if (r < 0 || c < 0) return "";
    
    int flI = 0;
    for (List<int> floatingBox in floatingRects) {
      if (r >= floatingBox[4] && r <= floatingBox[5]) {
        if (x > floatingBox[0] && x < (floatingBox[0] + floatingBox[2])
            && y > floatingBox[1] && y < (floatingBox[1] + floatingBox[3])) {
          
          return floatingRectDesc[flI];
          
        }
      }
      flI++;
    }
    
    // If not floating found, look beyond into the staves
    
    int boxI = 0;
    for (List<int> box in elementHitboxes[r][c]) {
      if (x > box[0] && x < (box[0] + box[2])
          && y > box[1] && y < (box[1] + box[3])) {
        return elementIDs[r][c][boxI];
      }
      boxI++;
    }
    
    return "";
  }
  
  String getElementGroupId(int x, int y) {
    int r = getRowIndex(y);
    int c = getColIndex(r, x);
    if (r < 0 || c < 0) return "";
    return elementGroupIDs[r][c+1];
  }
  
  List<String> getAllChildrenAtGroupPos(int x, int y) {
    int r = getRowIndex(y);
    int c = getColIndex(r, x);
    if (r < 0 || c < 0) return [];
    return elementIDs[r][c];
  }
  
  void initHitboxes(String imageSVG) {
    // Prep a list of things to parse later
    List<XmlElement> floatingRectElementsToParse = [];
    
    // Let the XML library parse the SVG document as an xml doc
    final doc = XmlDocument.parse(imageSVG);
    
    // Parse all the real bounds from each reused symbol
    parseSymbolTableBounds(doc.getElement(_SVG)!.getElement(_DEFS)!);
    
    // Scrape the page dimensions from the main SVG tag's attributes
    List<String> pageDims = doc.getElement(_SVG)!.getAttribute(_VIEWBOX)!.split(" ");
    pageWidth = int.parse(pageDims[2]);
    pageHeight = int.parse(pageDims[3]);
    
    // Make sure we are grabbing information correctly from the document
    XmlElement? pageMarginWrapper = doc.getElement(_SVG)?.getElement(_G);
    if (pageMarginWrapper == null || pageMarginWrapper.getAttribute(_CLASS) != _PAGE_MARGIN) {
      print("First element grab wasn't page margin!");
      print(pageMarginWrapper);
      return;
    }
    // Collect margin shift applied in the page-margin element
    String page_margins_string = pageMarginWrapper.getAttribute(_TRANSFORM) ?? "translate(0, 0)";
    List<String> transforms = page_margins_string.substring(10, page_margins_string.length-1).split(", ");
    pageOffsetX = int.parse(transforms[0]);
    pageOffsetY = int.parse(transforms[1]);
    
    // Read how many staves each line will have
    int staffCount = doc
      .xpath("/svg/g[@class='page-margin']/g[@class='system']/g[@class='measure']").first
      .xpath("./g[@class='staff']").length;
    
    // Create variable spaces for storing bounds between rows
    List<int> rowMaxY = List.filled(staffCount, -1, growable: false);
    List<int> rowMinY = List.filled(staffCount, -1, growable: false);
    int hangingRowMaxY = -1;
    
    // A system is a horizontal line of music comprised of measures
    for (XmlElement system in pageMarginWrapper!.findElements(_G)) {
      if (system.getAttribute(_CLASS) != _SYSTEM) continue;
      //print("----------=[ Starting System ]=----------");
      
      bool isFirstSystem = hangingRowMaxY == -1;
      
      // Fill in existing value for all min, max, and hanging
      hangingRowMaxY = isFirstSystem ? 0 : rowMaxY[rowMaxY.length-1];
      Iterable<XmlNode> staves = system
          .xpath("./g[@class='$_MEASURE']").first
          .xpath("./g[@class='$_STAFF']");
      int i = 0;
      for (XmlNode staff in staves) {
        Iterable<XmlElement> staffLines = staff.findElements(_PATH);
        rowMinY[i] = int.parse(staffLines.first.getAttribute(_D)!.split(" ")[1]) + pageOffsetY;
        rowMaxY[i] = int.parse(staffLines.last.getAttribute(_D)!.split(" ")[1]) + pageOffsetY;
        i++;
      }
      
      // Set up columnMarkers and elementIDs to accept more values (add new rows)
      // Get the index of rows that we will start with in this system
      int systemRowIndex = columnMarkers.length;
      // This is the start of the system (line).  Acts to define page margin in hitboxes
      int marginSeperator = int.parse(system.firstElementChild!.getAttribute(_D)!.split(" ")[0].substring(1));
      marginSeperator += pageOffsetX;
      // Add a new row for each staff.  Column marker gets margin seperator, and element ID for margin is ""
      columnMarkers.addAll(List.generate(staffCount, (_) => [marginSeperator]));
      elementGroupIDs.addAll(List.generate(staffCount, (_) => [""]));
      elementHitboxes.addAll(List.generate(staffCount, (_) => []));
      elementIDs.addAll(List.generate(staffCount, (_) => []));
      
      // Handle the measures themselves now
      for (XmlElement measure in system.childElements) {
        if (measure.getAttribute(_CLASS) != _MEASURE) continue;
        //print("----------=[ Starting Measure ]=----------");
        
        int measureEndX = 77;
        XmlElement firstStaff = measure.firstElementChild!;
        if (firstStaff.getAttribute(_CLASS) != _STAFF) {
          // If first wasn't staff (usually measure numbers), go to next
          firstStaff = measure.childElements.elementAt(1);
        }
        //
        List<String>? barLines = firstStaff.firstElementChild?.getAttribute(_D)?.split(" ");
        if (barLines == null) {
          print("Measure did not have bar lines!  measure first child: ${measure.firstElementChild}");
          // This must be the first measure of the line.  Grab 
        } else {
          measureEndX = int.parse(barLines[2].substring(1)) + pageOffsetX;
        }
       
        
        int measureStaffIndex = systemRowIndex;
        for (XmlElement measureChild in measure.childElements) {
          if (measureChild.getAttribute(_CLASS) != _STAFF) {
              if (SpecialRectsToGrabFromMeasure.contains(measureChild.getAttribute(_CLASS))) {
                floatingRectElementsToParse.add(measureChild);
              }
              // Don't move on to treat this like a staff
              continue;
          }
          //print("----------=[ Starting Staff $measureStaffIndex ]=----------");
          
          List< List<int> > boundList = [];
          List<String> idList = [];
          int layerIndex = 0;
          for (XmlElement staffChild in measureChild.findElements(_G)) {
            // Only take layers, and then unpack all their children
            if (XmlElementsToGrabFromStaff.contains(staffChild.getAttribute(_CLASS))) {
              unpackElementBounds(staffChild, boundList, idList, -1, layerIndex);
              if (staffChild.getAttribute(_CLASS) == _LAYER) layerIndex++;
            }
          }
          
          // Sort the hitboxes by their X position
          boundList.sort((a, b) => a[0].compareTo(b[0]));
          
          // For each group found, add:
          //  - columnMarker value in columnMarkers[measureStaffIndex]
          //  - elementGroupIDs value in elementGroupIDs[measureStaffIndex]
          //  - List of hitboxes in elementHitboxes[measureStaffIndex] (for group)
          //  - List of element IDs (string) in elementIDs[measureStaffIndex] (for group)
          //
          // For each group found, create:
          //  - int: Bound coordinate that marks left bound
          //  - String: Group id of groups (with slashes if multiple layers)
          //  - List<List<int>>: sorted bound boxes (for this group only)
          //  - List<String>: sorted string IDs (from int and id list)
          
          /// Local function that checks to see if the given hitbox makes
          /// any records for being the lowest or highest element in its
          /// row.  If so, the corresponding variable is updated.
          void checkMaxOrMinY(int hitboxIndex, int msi) {
            int tempI = msi % staffCount;
            if (boundList[hitboxIndex][1] < rowMinY[tempI]) {
              rowMinY[tempI] = boundList[hitboxIndex][1];
            }
            if (boundList[hitboxIndex][1] + boundList[hitboxIndex][3] > rowMaxY[tempI]) {
              rowMaxY[tempI] = boundList[hitboxIndex][1] + boundList[hitboxIndex][3];
            }
          }
          
          String groupIDString;
          int colI = elementHitboxes[measureStaffIndex].length;
          elementHitboxes[measureStaffIndex].add([]);
          elementIDs[measureStaffIndex].add([]);
          
          int thisGroupMaxX;
          
          // When representing a hitbox, 7 numbers are used.
          //  0  1    2      3       4    5      6
          // [X, Y, Width, Height, Layer, id, groupID]
          
          //  First Hitbox Steps:
          //    - Set thisGroupMaxX to this element X + Width
          //    - Set groupIDString to this groupID
          //    - Add hitbox to elementHitBoxes[msi][colI] (just indices 0-4) (don't add id ints)
          //    - Add element ID to elementIDs[msi][colI]
          //    - Check to see if it sets a maxY or minY
          //
          //  Per Hitbox Steps:
          //    - Check to see if it sets a maxY or minY
          //    - Check to see if it overlaps with previous group
          //      - If NO:
          //        - New group is found.
          //        - Calculate the 1/2-point between hitbox[i].x, and thisGroupMaxX
          //        - Add this value to columnMarkers[msi]
          //        - Add the group ID string to elementGroupIDs[msi]
          //        - Do resetting steps:
          //          - colI++
          //          - Add an empty list to elementHitBoxes[msi], and elementIDs[msi]
          //          - Set thisGroupMaxX to this element X + Width
          //          - Set groupIDString to this element's group ID
          //      - DO THESE STEPS for every hitbox, regardless of new group or not:
          //      - Add hitbox to elementHitBoxes[msi][colI] (just 0-4)
          //      - Add element ID to elementIDs[msi][colI]
          //      - Add hitbox group ID to group ID string (if not contains)
          //      - Check to see if this element's max X is new group record
          //
          //  When done with all hitboxes:
          //    - Add the right page margin seperator to the columnMarkers[msi]
          //    - Add the right page edge seperator to the columnMarkers[msi]
          //    - Add the groupIDString to elementGroupIDs[msi]
          //    - Add the string "" to elementGroupIDs
          
          // If no elements were found in layer, continue
          if (boundList.isEmpty) {
            print("Nothing in msi $measureStaffIndex somehow..");
            // Close things up
            columnMarkers[measureStaffIndex].add(measureEndX);
            elementGroupIDs[measureStaffIndex].add("");
            continue;
          }
          
          // Handle the first hitbox
          thisGroupMaxX = boundList[0][0] + boundList[0][2];
          groupIDString = idList[ boundList[0][6] ];
          elementHitboxes[measureStaffIndex][colI].add(boundList[0].sublist(0, 5));
          elementIDs[measureStaffIndex][colI].add(idList[ boundList[0][5] ]);
          checkMaxOrMinY(0, measureStaffIndex);
          
          // Handle all other hitboxes
          for (int i = 1; i < boundList.length; i++) {
            List<int> box = boundList[i];
            checkMaxOrMinY(i, measureStaffIndex);
            if (box[0] >= thisGroupMaxX) {
              // New Group
              int seperatingLine = (box[0] + thisGroupMaxX) ~/ 2;
              columnMarkers[measureStaffIndex].add(seperatingLine);
              elementGroupIDs[measureStaffIndex].add(groupIDString);
              // Resetting Steps
              colI++;
              elementHitboxes[measureStaffIndex].add([]);
              elementIDs[measureStaffIndex].add([]);
              thisGroupMaxX = box[0] + box[2];
              groupIDString = idList[ box[6] ];

            }
            // Do these steps for any hitbox
            elementHitboxes[measureStaffIndex][colI].add(box.sublist(0, 5));
            elementIDs[measureStaffIndex][colI].add(idList[ box[5] ]);
            if (!groupIDString.contains(idList[ box[6] ])) {
              groupIDString += "/${idList[ box[6] ]}";
            }
            thisGroupMaxX = max(thisGroupMaxX, box[0] + box[2]);
            
          } // End for loop
          
          // Close things up
          columnMarkers[measureStaffIndex].add(measureEndX);
          elementGroupIDs[measureStaffIndex].add(groupIDString);
          
          // Increment counter that represents that we are moving
          // down a line - to the next staff in the music downwards
          measureStaffIndex++;
        } // End Staff
        
      } // End measure
      
      // At end of each system (line of measures), add the right page margin to our hitbox system
      for (int j = systemRowIndex; j < systemRowIndex + staffCount; j++) {
        columnMarkers[j].add(pageWidth);
        elementGroupIDs[j].add("");
      }
      
      // Also add row markers to list
      rowMarkers.add( (rowMinY[0] + hangingRowMaxY) ~/ 2 );
      for (int i = 1; i < staffCount; i++) {
        rowMarkers.add( (rowMinY[i] + rowMaxY[i-1]) ~/ 2 );
      }
      
    } // End systems
    
    // Add a final row marker for the last layer
    rowMarkers.add( rowMaxY[rowMaxY.length-1] + LowestStaffHitboxMargin );
    
    // Do finishing steps of init
    parseAllFloatingRects(floatingRectElementsToParse);
    buildHitboxSvgElements();
  } // End initHitboxes
  
  void parseAllFloatingRects(List<XmlElement> els) {
    for (XmlElement el in els) {
      parseFloatingRect(el);
    }
  }
  
  void parseSymbolTableBounds(XmlElement root) {
    for (XmlElement symbol in root.childElements) {
      // There shouldn't ever be something here not called <symbol>.  But to be safe, skip them.
      if (symbol.name.toString() != _SYMBOL) continue;
      
      // Get information about the symbol in general
      String symbolID = symbol.getAttribute(_ID)!;
      
      // Select the path and make sure assumptions hold
      XmlElement path = symbol.childElements.first;
      if (path.getAttribute(_TRANSFORM) != "scale(1,-1)") {
        print("[SYMBOL PARSE] Path didn't have scale transform of 1,-1!  Was: [${path.getAttribute(_TRANSFORM)}]!");
      }
      
      String dataString = path.getAttribute(_D)!;
      
      // Get the actual bounds of the symbol
      List<int> bounds = getPathBounds(dataString);
      symbolBounds["#$symbolID"] = bounds;
      
    }
  }
  
  /// Returns a list of [minX, minY, width, height, maxX, maxY]
  List<int> getPathBounds(String path) {
    
    /// SVG Syntax:
    /// Capital letters use absolute positioning (x, y)
    /// Lower-case letters use relative positioning (dx, dy)
    /// Commands with multiple dx dy, etc are all relative to
    ///    the start position, not the last relative one.
    /// 
    /// M x y   -   -   -   - Move To
    /// L x y   -   -   -   - Line To
    /// H x -   -   -   -   - Horizontal Line
    /// V y -   -   -   -   - Vertical line
    /// C x1 y1 x2 y2 x3 y3 - Cubic curves (end at x3 y3)
    /// Z   -   -   -   -   - Line To Start
    /// S x2 y2 x3 y3   -   - Curve ends at x3 y3
    /// Q x1 y1 x2 y2   -   - Curve with one control point, and ends at x2 y2
    /// 
    
    // Take anything that isn't a (-), a digit, or a space, and pad it with spaces.
    List<String> data = "M ${path.replaceAll(",", " ").substring(1).replaceAllMapped(RegExp(r'[^0-9 \-]'), (match) {
      return " ${match.group(0)} ";
    })}".trimRight().split(" ");
    
    // Current position tracking (since most stuff is relative to last position)
    int currX = 0;
    int currY = 0;
    int firstX = int.parse(data[1]);
    int firstY = int.parse(data[2]);
    int minX = pageWidth,
        minY = pageHeight,
        maxX = 0,
        maxY = 0;
    // Purposely no automatic i increment.  Always increments differently based on command
    for (int i = 0; i < data.length; ) {
      switch (data[i]) {
        case "M":
          currX = int.parse(data[i+1]);
          currY = int.parse(data[i+2]);
          if (currX < minX) minX = currX;
          if (currX > maxX) maxX = currX;
          if (currY < minY) minY = currY;
          if (currY > maxY) maxY = currY;
          i += 3;
          break;
        case "m":
          currX += int.parse(data[i+1]);
          currY += int.parse(data[i+2]);
          if (currX < minX) minX = currX;
          if (currX > maxX) maxX = currX;
          if (currY < minY) minY = currY;
          if (currY > maxY) maxY = currY;
          i += 3;
          break;
        case "L":
          currX = int.parse(data[i+1]);
          currY = int.parse(data[i+2]);
          if (currX < minX) minX = currX;
          if (currX > maxX) maxX = currX;
          if (currY < minY) minY = currY;
          if (currY > maxY) maxY = currY;
          i += 3;
          break;
        case "l":
          currX += int.parse(data[i+1]);
          currY += int.parse(data[i+2]);
          if (currX < minX) minX = currX;
          if (currX > maxX) maxX = currX;
          if (currY < minY) minY = currY;
          if (currY > maxY) maxY = currY;
          i += 3;
          break;
        case "H":
          currX = int.parse(data[i+1]);
          if (currX < minX) minX = currX;
          if (currX > maxX) maxX = currX;
          i += 2;
          break;
        case "h":
          currX += int.parse(data[i+1]);
          if (currX < minX) minX = currX;
          if (currX > maxX) maxX = currX;
          i += 2;
          break;
        case "V":
          currY = int.parse(data[i+1]);
          if (currY < minY) minY = currY;
          if (currY > maxY) maxY = currY;
          i += 2;
          break;
        case "v":
          currY += int.parse(data[i+1]);
          if (currY < minY) minY = currY;
          if (currY > maxY) maxY = currY;
          i += 2;
          break;
        case "C":
          List<int> locals = parseCurveInPath(data, i, currX, currY, true, false);
          if (locals[0] < minX) minX = locals[0];
          if (locals[1] < minY) minY = locals[1];
          if (locals[2] > maxX) maxX = locals[2];
          if (locals[3] > maxY) maxY = locals[3];
          currX = locals[4];
          currY = locals[5];
          i += 7;
          break;
        case "c":
          List<int> locals = parseCurveInPath(data, i, currX, currY, true, true);
          if (locals[0] < minX) minX = locals[0];
          if (locals[1] < minY) minY = locals[1];
          if (locals[2] > maxX) maxX = locals[2];
          if (locals[3] > maxY) maxY = locals[3];
          currX = locals[4];
          currY = locals[5];
          i += 7;
          break;
        case "Z":
        case "z":
          currX = firstX;
          currY = firstY;
          i += 1;
          break;
        case "S":
        case "Q":
          List<int> locals = parseCurveInPath(data, i, currX, currY, false, false);
          if (locals[0] < minX) minX = locals[0];
          if (locals[1] < minY) minY = locals[1];
          if (locals[2] > maxX) maxX = locals[2];
          if (locals[3] > maxY) maxY = locals[3];
          currX = locals[4];
          currY = locals[5];
          i += 5;
          break;
        case "s":
        case "q":
          List<int> locals = parseCurveInPath(data, i, currX, currY, false, true);
          if (locals[0] < minX) minX = locals[0];
          if (locals[1] < minY) minY = locals[1];
          if (locals[2] > maxX) maxX = locals[2];
          if (locals[3] > maxY) maxY = locals[3];
          currX = locals[4];
          currY = locals[5];
          i += 5;
          break;
        case "":
        case " ":
          i++;
          continue;
        // I'm not supporting T and t right now.  I don't think Verovio uses those
        default:
          print("Unexpected svg command: ${data[i]}!");
          i++;
          continue;
      } // end Switch
    } // end For block
    
    return [minX, minY, (maxX - minX), (maxY - minY), maxX, maxY];
    
  }
  
  /// Returns [minX, minY, maxX, maxY, endX, endY] for a curve.
  List<int> parseCurveInPath(List<String> data, int i, int currX, int currY, bool twoControls, bool relative) {
    int minX = currX,
        minY = currY,
        maxX = currX,
        maxY = currY;
    
    int ctrX1, ctrY1, ctrX2 = 0, ctrY2 = 0, endX, endY;
    if (relative) {
      ctrX1 = currX + int.parse(data[i+1]);
      ctrY1 = currY + int.parse(data[i+2]);
      if (twoControls) {
        ctrX2 = currX + int.parse(data[i+3]);
        ctrY2 = currY + int.parse(data[i+4]);
        endX = currX + int.parse(data[i+5]);
        endY = currY + int.parse(data[i+6]);
      } else {
        endX = currX + int.parse(data[i+3]);
        endY = currY + int.parse(data[i+4]);
      }
    } else {
      ctrX1 = int.parse(data[i+1]);
      ctrY1 = int.parse(data[i+2]);
      if (twoControls) {
        ctrX2 = int.parse(data[i+3]);
        ctrY2 = int.parse(data[i+4]);
        endX = int.parse(data[i+5]);
        endY = int.parse(data[i+6]);
      } else {
        endX = int.parse(data[i+3]);
        endY = int.parse(data[i+4]);
      }
      
    }
    
    int diffX = endX - currX;
    int diffXabs = diffX > 0 ? diffX : -diffX;
    int diffY = endY - currY;
    int diffYabs = diffY > 0 ? diffY : -diffY;
    if (diffXabs > diffYabs) {
      // Real curve movement is in Y direction
      int maxCtrY = ctrY1;
      if (twoControls && ctrY2 > ctrY1) maxCtrY = ctrY2;
      int minCtrY = ctrY1;
      if (twoControls && maxCtrY == ctrY1) minCtrY = ctrY2;
      if (maxCtrY > currY) {
        // Curve goes towards +y
        int curveMaxY = (maxCtrY + currY) ~/ 2;
        if (endY < minY) minY = endY;
        if (curveMaxY > maxY) maxY = curveMaxY;
      } else {
        // Curve goes towards -y
        int curveMinY = (minCtrY + currY) ~/ 2;
        if (curveMinY < minY) minY = curveMinY;
        if (endY > maxY) maxY = endY;
      }
      // Check X max/min with new point
      if (endX < minX) minX = endX;
      if (endX > maxX) maxX = endX;
    } else {
      // Real curve movement is in X direction
      int maxCtrX = ctrX1;
      if (twoControls && ctrX2 > ctrX1) maxCtrX = ctrX2;
      int minCtrX = ctrX1;
      if (twoControls && maxCtrX == ctrX1) minCtrX = ctrX2;
      if (maxCtrX > currX) {
        // Curve goes towards +x
        int curveMaxX = (maxCtrX + currX) ~/ 2;
        if (endX < minX) minX = endX;
        if (curveMaxX > maxX) maxX = curveMaxX;
      } else {
        // Curve goes towards -x
        int curveMinX = (minCtrX + currX) ~/ 2;
        if (curveMinX < minX) minX = curveMinX;
        if (endX > maxX) maxX = endX;
      }
      // Check Y max/min with new point
      if (endY < minY) minY = endY;
      if (endY > maxY) maxY = endY;
    }
    
    return [minX, minY, maxX, maxY, endX, endY];
  }
  
  /// Recursive method to pull all individual elements from a measure line
  /// for further processing afterwards.
  void unpackElementBounds(XmlElement el, List< List<int> > boundsList, List<String> idList, int groupID, int layer) {
    if (el.name.toString() != _G) return;
    
    String elClass = el.getAttribute(_CLASS) ?? "";
    //print("Unpacking el class $elClass");
    
    int elID = -1;
    if (!ElementsWhoseIDToIgnore.contains(elClass)) {
      String? elIDString = el.getAttribute(_ID);
      if (elIDString == null) {
        print("[Unpacker] Found element without ID! (${el.name})");
        return;
      }
      elID = idList.length;
      idList.add(elIDString);
    }
    
    // Check to see if this element should be ignored
    if (ElementsToIgnoreDuringUnpacking.contains(elClass)) { return; }
    
    // Check to see if this element should be split up before unpacking
    else if (ElementsToUnpackFurther.contains(elClass)) {
      for (XmlElement childEl in el.childElements) {
        unpackElementBounds(childEl, boundsList, idList, elID, layer);
      }
    
    // Otherwise, unpack this element (scrape it's bounds from the svg)
    } else {
      
      switch (elClass) {
        case _NOTE:
          extractHitboxOfNote(el, boundsList, idList, groupID, elID, layer);
          break;
        case _REST:
        case _MREST:
        case _CLEF:
          extractHitboxOfSingleElement(el, boundsList, idList, groupID, elID, layer);
          break;
        case _KEYACCID:
          extractHitboxOfKeyAccidental(el, boundsList, idList, groupID, elID, layer);
          break;
        case _METERSIG:
          extractHitboxOfMeterSignature(el, boundsList, idList, groupID, elID, layer);
          break;
        default:
          print("[Unpacker] Element class not expected!  Class: $elClass");
          break;
      }
    } // end Else clause
    
  } // end unpackElementBounds
  
  void extractHitboxOfNote(XmlElement el, List<List<int>> boundsList, List<String> idList, int groupID, int elementID, int layer) {
    // This method gets the bounds of a note, but also
    //  gets the bounds of any connecting accidentals.
    //  The hitboxes are then designed to overlap by 1 pixel,
    //  so that they are put into a group together but still
    //  have seperate hitboxes
    
    //print("Extracting: ${idList[elementID]} ($elementID) From: $idList");
    
    // Check appropriate group ID
    if (groupID == -1) {
      // If no group holds this, then the group ID = element ID for insertion purposes
      groupID = elementID;
    }
    
    // Get the bounds of the notehead
    List<int> noteUseBounds = parseXYWH(el.firstElementChild!.firstElementChild!);
    
    // Find the tag ID that the <use> tag references (within notehead)
    String? elTagID = el.firstElementChild?.firstElementChild?.getAttribute(_XLINKHREF);
    if (elTagID == null) {
      print("Failed to get tag ID!  elID: $elementID.");
      elTagID = "";
    }
    
    // Call method to adjust the Hitbox to fit actual glyph
    List<int> noteBounds = getBoundsAfterScaling(noteUseBounds, elTagID);
    
    // Add in information about IDs and layer, and add to master list of hitboxes
    noteBounds.addAll([layer, elementID, groupID]);
    boundsList.add(noteBounds);
    
    // Check for accidentals tied to this note
    for (XmlElement child in el.childElements) {
      // Also check to see if it has children.  For some reason, some scores cause a lot
      // of accid tags to be generated, with no effect or children.
      if (child.getAttribute(_CLASS) == _ACCID && child.children.isNotEmpty) {
        // Parse the accidental found
        
        // Get accidental ID and add to the ID list (to allow integer representation)
        int accidId = idList.length;
        idList.add(child.getAttribute(_ID)!);
        
        // Parse accidental bounds (except for width)
        List<int> accidUseBounds = parseXYWH(child.firstElementChild!);
        
        // Find the tag ID that the <use> tag references
        String? accidTagID = child.firstElementChild?.getAttribute(_XLINKHREF);
        if (accidTagID == null) {
          print("Failed to get tag ID for accidental!");
          accidTagID = "";
        }
        
        // Call method to adjust the Hitbox to fit actual glyph
        List<int> accidBounds = getBoundsAfterScaling(accidUseBounds, accidTagID);
        
        // Override the width so that it overlaps with notehead by 1 pixel (to classify as grouped)
        accidBounds[2] = (noteBounds[0] - accidBounds[0]) + 1;
        
        // Add accidental bounds to master bounds list
        // (group ID is same as note, with unique element ID)
        accidBounds.addAll([layer, accidId, groupID]);
        // Add hitbox to end list
        boundsList.add(accidBounds);
      }
    }
    
  }
  
  void extractHitboxOfSingleElement(XmlElement el, List<List<int>> boundsList, List<String> idList, int groupID, int elementID, int layer) {
    // Check appropriate group ID
    if (groupID == -1) {
      // If no group holds this, then the group ID = element ID for insertion purposes
      groupID = elementID;
    }
    
    // Parse the x, y, width, and height mentioned in the <use> tag
    List<int> elUseBounds = parseXYWH(el.firstElementChild!);
    
    // Find the tag ID that the <use> tag references
    String? elTagID = el.firstElementChild?.getAttribute(_XLINKHREF);
    if (elTagID == null) {
      print("Failed to get tag ID!");
      elTagID = "";
    }
    
    // Call method to adjust the Hitbox to fit actual glyph
    List<int> bounds = getBoundsAfterScaling(elUseBounds, elTagID);
    
    // Add in metadata about hitbox
    bounds.addAll([ layer, elementID, groupID ]);
    // Add hitbox to end list
    boundsList.add(bounds);
  }
  
  /// Same as single element, but make it a bit wider so it overlaps with neighbors
  void extractHitboxOfKeyAccidental(XmlElement el, List<List<int>> boundsList, List<String> idList, int groupID, int elementID, int layer) {
    // Check appropriate group ID
    if (groupID == -1) {
      // If no group holds this, then the group ID = element ID for insertion purposes
      groupID = elementID;
    }
    
    // Parse the x, y, width, and height mentioned in the <use> tag
    List<int> elUseBounds = parseXYWH(el.firstElementChild!);
    
    // Find the tag ID that the <use> tag references
    String? elTagID = el.firstElementChild?.getAttribute(_XLINKHREF);
    if (elTagID == null) {
      print("Failed to get tag ID!");
      elTagID = "";
    }
    
    // Call method to adjust the Hitbox to fit actual glyph
    List<int> bounds = getBoundsAfterScaling(elUseBounds, elTagID);
    
    // KEY SIGNATURE SPECIFIC STUFF HERE (Make make a bit wider)
    // Shift left a bit
    bounds[0] -= KeyAccidExtraWidth ~/ 2;
    // Make box wider
    bounds[2] += KeyAccidExtraWidth;
    
    // Add in metadata about hitbox
    bounds.addAll([ layer, elementID, groupID ]);
    // Add hitbox to end list
    boundsList.add(bounds);
  }
  
  /// Same as normal, but assume two <use> tags, second one underneath the first.
  void extractHitboxOfMeterSignature(XmlElement el, List<List<int>> boundsList, List<String> idList, int groupID, int elementID, int layer) {
    // Check appropriate group ID
    if (groupID == -1) {
      // If no group holds this, then the group ID = element ID for insertion purposes
      groupID = elementID;
    }
    
    XmlElement child1 = el.childElements.elementAt(0);
    XmlElement child2 = el.childElements.elementAt(1);
    
    // Parse the x, y, width, and height mentioned in the <use> tag
    List<int> elUseBounds1 = parseXYWH(child1);
    List<int> elUseBounds2 = parseXYWH(child2);
    
    // Find the tag ID that the <use> tag references
    String? elTagID1 = child1.getAttribute(_XLINKHREF);
    if (elTagID1 == null) {
      print("Failed to get tag ID! (for meter sig 1)");
      elTagID1 = "";
    }
    String? elTagID2 = child2.getAttribute(_XLINKHREF);
    if (elTagID2 == null) {
      print("Failed to get tag ID! (for meter sig 2)");
      elTagID2 = "";
    }
    
    // Call method to adjust the Hitbox to fit actual glyph
    List<int> bounds1 = getBoundsAfterScaling(elUseBounds1, elTagID2);
    List<int> bounds2 = getBoundsAfterScaling(elUseBounds2, elTagID2);
    
    // Add in metadata about hitbox
    bounds1.addAll([ layer, elementID, groupID ]);
    bounds2.addAll([ layer, elementID, groupID ]);
    // Add hitbox to end list
    boundsList.add(bounds1);
    boundsList.add(bounds2);
  }
  
  /// Returns a list containing the adjusted [x, y, width, height]
  List<int> getBoundsAfterScaling(List<int> elUseBounds, String elTagID, ) {
    
    List<int>? elSymbolBounds = symbolBounds[elTagID];
    if (elSymbolBounds == null) {
      print("Could not find bounds for tagID: $elTagID!");
      return [0, 0, 0, 0];
    }
    
    //                   0     1     2      3       4     5
    // symbolBounds is  [minX, minY, width, height, maxX, maxY]
    //                   0  1  2      3
    // elUseBounds is   [x, y, width, height]
    // Steps: 
    // left bound is X + ((vpwidth + minX - symbolWidth) * (width / vpwidth))
    // top  bound is Y + ((vpheight + maxY - symbolHeight) * (height / vpheight))
    // width  is symbolWidth  * (width / vpwidth)
    // height is symbolHeight * (height / vpheight)
    
    double scalar = elUseBounds[2] / ASSUMED_SYMBOL_VIEWPORT_SIZE;
    return [
      pageOffsetX + elUseBounds[0] + (elSymbolBounds[0] * scalar).round(),
      pageOffsetY + elUseBounds[1] + (-elSymbolBounds[5] * scalar).round(),
      (elSymbolBounds[2] * scalar).round(),
      (elSymbolBounds[3] * scalar).round()
    ];
  }
  
  /// Parses attributes called "x", "y", "width", and "height" as integers
  /// from the passed element, and removes the last 2 characters from the
  /// last two with the assumption that they end with "px".
  List<int> parseXYWH(XmlElement el) {
    
    String? width = el.getAttribute(_WIDTH);
    if (width == null) {
      print("\nProblem!  Element does not have $_WIDTH! El: ${el.name} (${el.attributes})");
      return [0, 0, 1, 1];
    }
      String? height = el.getAttribute(_HEIGHT);
    if (height == null) {
      print("\nProblem!  Element does not have $_HEIGHT! El: ${el.name} (${el.getAttribute("id")})");
      return [0, 0, 1, 1];
    }
    String? elX = el.getAttribute(_X);
    if (elX == null) {
      print("\nProblem!  Element does not have $_X! El: ${el.name} (${el.getAttribute("id")})");
      return [0, 0, 1, 1];
    }
    String? elY = el.getAttribute(_Y);
    if (elY == null) {
      print("\nProblem!  Element does not have $_Y! El: ${el.name} (${el.getAttribute("id")})");
      return [0, 0, 1, 1];
    }
    
    return [
      int.parse(elX),
      int.parse(elY),
      int.parse(width.substring(0, width.length-2)), // Remove last 2 chars because length and width end in "px"
      int.parse(height.substring(0, height.length-2))
    ];
  } 
  
  void parseFloatingRect(XmlElement el) {
    
    String elClass = el.getAttribute(_CLASS) ?? "";
    
    switch (elClass) {
      case _TIE:
        parseFloatingTieRect(el);
        break;
      case _HAIRPIN:
        parseFloatingHairPinRect(el);
        break;
      case _DYNAM:
        parseFloatingDynamRect(el);
        break;
      case _SLUR:
        parseFloatingSlurRect(el);
        break;
      case _DIR:
        parseFloatingDirRect(el);
        break;
      default:
        print("Unknown floating rect type: [$elClass] !");
    }
  }
  
  void parseFloatingTieRect(XmlElement el) {
    /*<g id="t1awxv0b" class="tie">
      <path d="M13761,5387 C13828,5495 13902,5495 13972,5387 C13932,5541 13797,5541 13761,5387" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="9" />
    </g>*/
    
    // In future, use slur method. This is close enough for now though.
    
    XmlElement elUse = el.firstElementChild!;
    List<int> tieBounds = getPathBounds(elUse.getAttribute(_D)!);
    tieBounds[0] += pageOffsetX;
    tieBounds[1] += pageOffsetY;
    
    int minRowIndex = getRowIndex(tieBounds[1]);
    int maxRowIndex = getRowIndex(tieBounds[1] + tieBounds[3]);
    floatingRects.add([
      tieBounds[0],
      tieBounds[1],
      tieBounds[2],
      tieBounds[3],
      minRowIndex,
      maxRowIndex
    ]);
    floatingRectDesc.add("$_TIE:${el.getAttribute(_ID)}");
  }
  
  void parseFloatingHairPinRect(XmlElement el) {
    /*<g id="h736oid" class="hairpin">
      <polyline stroke="currentColor" stroke-width="18" stroke-linecap="square" stroke-linejoin="miter" fill="none" points="13603,6566 12118,6431 13603,6296 " />
    </g>*/
    
    int maxX = 0, maxY = 0, minX = pageWidth, minY = pageHeight;
    XmlElement? fchild = el.firstElementChild;
    if (fchild == null) return;
    String pointsString = fchild.getAttribute(_POINTS)!;
    for (String pointString in pointsString.trim().split(" ")) {
      List<String> pos = pointString.trim().split(",");
      if (pos.isEmpty) continue;
      int x = int.parse(pos[0]);
      int y = int.parse(pos[1]);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    
    int width = maxX - minX;
    int height = maxY - minY;
    minX += pageOffsetX;
    minY += pageOffsetY;
    
    int minRowIndex = getRowIndex(minY);
    int maxRowIndex = getRowIndex(maxY + pageOffsetY);
    floatingRects.add([minX, minY, width, height, minRowIndex, maxRowIndex]);
    floatingRectDesc.add("$_HAIRPIN:${el.getAttribute(_ID)}");
  }
  
  void parseFloatingDynamRect(XmlElement el) {
    /*<g id="dx64erm" class="dynam">
      <title class="labelAttr">direction</title>
      <use xlink:href="#E520-10ny6tc" x="4993" y="6476" height="720px" width="720px" />
    </g>*/
    
    XmlElement? useTag;
    for (XmlElement child in el.childElements) {
      if (child.name.toString() == _USE) {
        useTag = child;
        break;
      }
    }
    if (useTag == null) {
      print("Cannot find use tag as child of dynam! Element:\n$el");
      return;
    }
    List<int> elUseBounds = parseXYWH(useTag);
    
    // Find the tag ID that the <use> tag references
    String? elTagID = useTag.getAttribute(_XLINKHREF);
    if (elTagID == null) {
      print("Failed to get tag ID!");
      elTagID = "";
    }
    
    // Call method to adjust the Hitbox to fit actual glyph
    List<int> bounds = getBoundsAfterScaling(elUseBounds, elTagID);
    
    int minRowIndex = getRowIndex(bounds[1]);
    int maxRowIndex = getRowIndex(bounds[1] + bounds[3]);
    floatingRects.add([
      bounds[0],
      bounds[1],
      bounds[2],
      bounds[3],
      minRowIndex,
      maxRowIndex
    ]);
    floatingRectDesc.add("$_DYNAM:${el.getAttribute(_ID)}");
  }
  
  void parseFloatingDirRect(XmlElement el) {
    /*<g id="d1x1taea" class="dir">
      <text x="3189" y="276" font-size="0px">
          <tspan id="rk2beft" class="rend">
            <tspan id="t11cm0tu" class="text">
                <tspan font-size="405px">Not fast.</tspan>
            </tspan>
          </tspan>
      </text>
    </g>*/
    
    // Not sure how to get dimensions of svg text yet.
    
  }
  
  void parseFloatingSlurRect(XmlElement el) {
    /*<g id="sok2s56" class="slur">
      <path d="M5430,8379 C5736,8490 6165,8235 6252,7749 C6223,8273 5739,8558 5430,8379" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="9" />
    </g>*/
    // Do nothing for now.  Not sure how to select a slur
  }
  
  String getHitboxSvgElements() {
    return currentHitboxSvg;
  }
  
  void buildHitboxSvgElements() {
    
    //String svg = "<svg viewBox='0 0 $pageWidth $pageHeight' width='2100px' height='2970px'><g>";
    String svg = "<g class='hitbox-elements'>";
    
    for (int row in rowMarkers) {
      // Draw the row lines (RED)
      svg += "<path d='M0 $row L$pageWidth $row' stroke='#FF0000' stroke-width='22' />";
    }
    
    for (int r = 0; r < rowMarkers.length-1; r++) {
      for (int col in columnMarkers[r]) {
        // Draw the column Lines (BLUE)
        svg += "<path d='M$col ${rowMarkers[r]} L$col ${rowMarkers[r+1]}' stroke='#0000FF' stroke-width='17' />";
      }
    }
    
    for (int r = 0; r < elementHitboxes.length; r++) {
      for (int c = 0; c < elementHitboxes[r].length; c++) {
        for (int g = 0; g < elementHitboxes[r][c].length; g++) {
          List<int> box = elementHitboxes[r][c][g];
          int endX = box[0] + box[2];
          int endY = box[1] + box[3];
          // Draw an X per hitbox
          svg += "<path d='M${box[0]} ${box[1]}, $endX $endY' stroke='#00FF00' stroke-width='20' data-id='${elementIDs[r][c][g]}' />";
          svg += "<path d='M$endX ${box[1]}, ${box[0]} $endY' stroke='#00FF00' stroke-width='20' data-id='${elementIDs[r][c][g]}' />";
        }
      }
    }
    
    for (int i = 0; i < floatingRects.length; i++) {
      List<int> box = floatingRects[i];
      int endX = box[0] + box[2];
      int endY = box[1] + box[3];
      // Draw an X per hitbox
      svg += "<path d='M${box[0]} ${box[1]}, $endX $endY' stroke='#00FF00' stroke-width='20' data-id='${floatingRectDesc[i]}' />";
      svg += "<path d='M$endX ${box[1]}, ${box[0]} $endY' stroke='#00FF00' stroke-width='20' data-id='${floatingRectDesc[i]}' />";
    }

    //svg += "</g></svg>";
    svg += "</g>";
    
    currentHitboxSvg = svg;
  }
  
} // end Class

