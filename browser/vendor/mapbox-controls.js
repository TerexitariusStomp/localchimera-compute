/*!
 * mapbox-controls, vendored — https://github.com/korywka/mapbox-controls (MIT)
 *
 * Hand-converted from the upstream @mapbox-controls/{helpers,zoom,compass,inspect}
 * ES-module sources (each a few hundred lines) into one plain, dependency-free
 * script — no bundler, no bare `@mapbox-controls/…` import specifiers a browser
 * can't resolve. Base container classes read `maplibregl-ctrl`/`maplibregl-ctrl-group`, not
 * `mapboxgl-ctrl` — this map is maplibre-gl, and those are the classes its own
 * vendored CSS actually styles, so a button here looks native, not bolted on.
 *
 * Same loading discipline as maplibre-gl.js / d3 / topojson: a same-origin
 * <script> tag, works over the onion / offline, exposes window.MapboxControls.
 */
(function (global) {
  "use strict";

  // ── helpers (@mapbox-controls/helpers) ──────────────────────────────────
  function controlContainer(className) {
    var container = document.createElement("div");
    container.classList.add("maplibregl-ctrl", "maplibregl-ctrl-group", className);
    return container;
  }
  function controlButton(options) {
    options = options || {};
    var button = document.createElement("button");
    button.type = "button";
    if (options.title) button.title = options.title;
    if (options.icon) button.appendChild(options.icon);
    if (options.textContent) button.textContent = options.textContent;
    if (options.disabled) button.disabled = true;
    if (options.hidden) button.hidden = true;
    if (options.className) button.classList.add(options.className);
    if (options.onClick) button.addEventListener("click", function () { options.onClick(); });
    return button;
  }
  function parseSVG(str) {
    return new DOMParser().parseFromString(str, "image/svg+xml").firstChild;
  }

  // ── ZoomControl (@mapbox-controls/zoom) ─────────────────────────────────
  function zoomIcon(d) {
    return parseSVG(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="23" height="23" fill="currentColor">' +
      '<rect fill="none" height="24" width="24"/><path d="' + d + '"/></svg>');
  }
  var ZOOM_PLUS = "M18,13h-5v5c0,0.55-0.45,1-1,1l0,0c-0.55,0-1-0.45-1-1v-5H6c-0.55,0-1-0.45-1-1l0,0c0-0.55,0.45-1,1-1h5V6 c0-0.55,0.45-1,1-1l0,0c0.55,0,1,0.45,1,1v5h5c0.55,0,1,0.45,1,1l0,0C19,12.55,18.55,13,18,13z";
  var ZOOM_MINUS = "M18,13H6c-0.55,0-1-0.45-1-1l0,0c0-0.55,0.45-1,1-1h12c0.55,0,1,0.45,1,1l0,0C19,12.55,18.55,13,18,13z";

  function ZoomControl() {
    this.container = controlContainer("mapbox-ctrl-zoom");
    var self = this;
    this.buttonIn = controlButton({ title: "Zoom In", icon: zoomIcon(ZOOM_PLUS),
      onClick: function () { if (self.map) self.map.zoomIn(); } });
    this.buttonOut = controlButton({ title: "Zoom Out", icon: zoomIcon(ZOOM_MINUS),
      onClick: function () { if (self.map) self.map.zoomOut(); } });
  }
  ZoomControl.prototype.onAdd = function (map) {
    this.map = map;
    this.container.appendChild(this.buttonIn);
    this.container.appendChild(this.buttonOut);
    return this.container;
  };
  ZoomControl.prototype.onRemove = function () {
    if (this.container.parentNode) this.container.parentNode.removeChild(this.container);
  };

  // ── CompassControl (@mapbox-controls/compass) ───────────────────────────
  function compassIcon() {
    return parseSVG(
      '<svg viewBox="0 0 24 24" width="25" height="25" xmlns="http://www.w3.org/2000/svg">' +
      '<g fill="none" fill-rule="evenodd"><path d="M0 0h24v24H0z"/>' +
      '<path fill="#f44336" d="M12 3l4 8H8z"/><path fill="#9E9E9E" d="M12 21l-4-8h8z"/></g></svg>');
  }
  function CompassControl(options) {
    this.options = options || {};
    this.container = controlContainer("mapbox-ctrl-compass");
    this.icon = compassIcon();
    var self = this;
    this.button = controlButton({ title: this.options.title || "Compass", icon: this.icon,
      onClick: function () { self.onClick(); } });
  }
  // `options.onClick(map)` may claim the click by returning true (the app's
  // own addition: the needle also turns on the phone's heading-up); otherwise
  // upstream's behaviour — back to north, level.
  CompassControl.prototype.onClick = function () {
    if (!this.map) return;
    if (this.options.onClick && this.options.onClick(this.map) === true) return;
    this.map.easeTo({ bearing: 0, pitch: 0 });
  };
  CompassControl.prototype.onRotate = function () {
    var angle = this.map.getBearing() * -1;
    if (!this.options.instant) this.container.hidden = angle === 0;
    this.icon.style.rotate = angle + "deg";
  };
  CompassControl.prototype.onAdd = function (map) {
    this.map = map;
    if (!this.options.instant) this.container.hidden = true;
    this.container.appendChild(this.button);
    this.onRotate();
    var self = this;
    map.on("rotate", function () { self.onRotate(); });
    return this.container;
  };
  CompassControl.prototype.onRemove = function () {
    if (this.container.parentNode) this.container.parentNode.removeChild(this.container);
  };

  // ── InspectControl (@mapbox-controls/inspect) ───────────────────────────
  // Click a rendered feature to see its layer id/type/source and properties
  // — a debugging tool, not a citizen-facing one. Reads whatever IS a real
  // maplibre layer at the click point: any deck.gl-adjacent GeoJSON layer a
  // future face adds, the raster tile
  // layers themselves (source/type only — a raster tile carries no
  // per-feature properties to show). The DOM markers everything else on
  // this map draws (needs, offers, places) aren't maplibre layers at all,
  // so this can't see them — a real, known gap, not a bug.
  function inspectIcon() {
    return parseSVG(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="23" height="23" fill="currentColor">' +
      '<path d="M0 0h24v24H0z" fill="none"/><path d="M20 19.59V8l-6-6H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c0.45 0 0.85-0.15 1.19-0.4l-4.43-4.43c-0.8,0.52-1.74,0.83-2.76,0.83-2.76,0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5c0 1.02-0.31 1.96-0.83 2.75L20 19.59zM9 13c0 1.66 1.34 3 3 3s3-1.34 3-3-1.34-3-3-3-3 1.34-3 3z"/></svg>');
  }
  function inspectPopupHTML(features, current) {
    var f = features[current];
    var props = f.properties || {};
    var keys = Object.keys(props);
    var layer = f.layer || {};
    var rows = "";
    if (f.id !== undefined) rows += "<tr><th>$id</th><td>" + f.id + "</td></tr>";
    rows += '<tr><td colspan="2">layer</td></tr>' +
      "<tr><th>id</th><td>" + layer.id + "</td></tr>" +
      "<tr><th>type</th><td>" + layer.type + "</td></tr>" +
      "<tr><th>source</th><td>" + layer.source + "</td></tr>" +
      "<tr><th>source-layer</th><td>" + (layer["source-layer"] || "-") + "</td></tr>";
    if (keys.length) {
      rows += '<tr><td colspan="2">properties</td></tr>';
      rows += keys.map(function (k) { return "<tr><th>" + k + "</th><td>" + props[k] + "</td></tr>"; }).join("");
    }
    var nav = features.length > 1
      ? "<button data-prev>←</button><nav>" + (current + 1) + " / " + features.length + "</nav><button data-next>→</button>"
      : "<nav>" + (current + 1) + " / " + features.length + "</nav>";
    return "<header>" + nav + "</header><table>" + rows + "</table>";
  }
  function inspectPopup(features) {
    var node = document.createElement("div");
    var current = 0;
    node.className = "mapbox-ctrl-inspect-popup";
    if (!features.length) { node.textContent = "No features"; return node; }
    node.innerHTML = inspectPopupHTML(features, current);
    node.addEventListener("click", function (e) {
      var t = e.target;
      if (t.matches("[data-prev]")) current = current === 0 ? features.length - 1 : current - 1;
      else if (t.matches("[data-next]")) current = current === features.length - 1 ? 0 : current + 1;
      else return;
      node.innerHTML = inspectPopupHTML(features, current);
    });
    return node;
  }
  function InspectControl(options) {
    this.options = options || {};
    this.container = controlContainer("mapbox-ctrl-inspect");
    var self = this;
    this.button = controlButton({ title: "Inspect", icon: inspectIcon(),
      onClick: function () { self.isActive ? self.deactivate() : self.activate(); } });
    this.isActive = false;
    this.mapClickListener = function (e) {
      self.lngLat = e.lngLat;
      var pt = e.point, t = 3;
      var features = self.map.queryRenderedFeatures([[pt.x - t, pt.y + t], [pt.x + t, pt.y - t]]);
      self.hideDetails();
      self.showDetails(features);
    };
    this.updatePosition = function () {
      if (!self.lngLat || !self.detailsNode) return;
      var canvasRect = self.map.getCanvas().getBoundingClientRect();
      var pos = self.map.project([self.lngLat.lng, self.lngLat.lat]);
      self.detailsNode.style.left = (pos.x - canvasRect.left) + "px";
      self.detailsNode.style.top = (pos.y - canvasRect.top) + "px";
    };
  }
  InspectControl.prototype.activate = function () {
    this.isActive = true;
    this.button.classList.add("-active");
    this.map.on("click", this.mapClickListener);
    this.map.on("move", this.updatePosition);
    this.map.getCanvas().style.cursor = "pointer";
  };
  InspectControl.prototype.deactivate = function () {
    this.isActive = false;
    this.button.classList.remove("-active");
    this.map.off("click", this.mapClickListener);
    this.map.off("move", this.updatePosition);
    this.map.getCanvas().style.cursor = "";
    this.hideDetails();
  };
  InspectControl.prototype.showDetails = function (features) {
    this.detailsNode = inspectPopup(features);
    this.map.getContainer().appendChild(this.detailsNode);
    this.updatePosition();
  };
  InspectControl.prototype.hideDetails = function () {
    if (!this.detailsNode) return;
    this.map.getContainer().removeChild(this.detailsNode);
    this.detailsNode = undefined;
  };
  InspectControl.prototype.onAdd = function (map) {
    this.map = map;
    this.container.appendChild(this.button);
    return this.container;
  };
  InspectControl.prototype.onRemove = function () {
    this.deactivate();
    if (this.container.parentNode) this.container.parentNode.removeChild(this.container);
  };

  global.MapboxControls = { ZoomControl: ZoomControl, CompassControl: CompassControl,
    InspectControl: InspectControl };
})(window);
