{ EventEmitter }                                  = require 'events'
{ CompositeDisposable, Range, Point, TextEditor } = require 'atom'
RemoteCursorView                                  = require './remote-cursor-view'
fs                                                = require 'fs'

class EventHandler

  constructor: (@remoteClient) ->
    @emitter = new EventEmitter
    @project = atom.project
    @workspace = atom.workspace
    @subscriptions = new CompositeDisposable
    @localChange = false
    @userEmail =  atom.config.get('motepair.userEmail')
    @lastCursorChange = new Date().getTime()
    @remoteAction = false
    if process.platform is "win32"
        @seperator = '\\'
    else
        @seperator = '/'
    @syncTabsEvents = [ 'open', 'close' ]

  onopen: (data) ->
    path = @locateFilePath(data)
    @remoteAction = true
    @workspace.open(path)
    setTimeout =>
      @remoteAction = false
    , 300

  onclose: (data) ->
    closedItem = null

    @workspace.getPaneItems().forEach (item) =>
      closedItem = item if item.getPath? and item.getPath() is @locateFilePath(data)

    @remoteAction = true
    @workspace.getActivePane().destroyItem closedItem
    setTimeout =>
      @remoteAction = false
    , 300

  onsave: (data) ->
    @remoteAction = true
    @workspace.getPaneItems().forEach (item) =>
      item.save() if item.getPath? and item.getPath() is @locateFilePath(data)
    setTimeout =>
      @remoteAction = false
    , 300

  onselect: (data) ->
    editor = atom.workspace.getActivePaneItem()
    return unless editor? and editor.getPath? and @locateFilePath(data) is editor.getPath()
    editor.selectionMarker?.destroy()
    unless Point.fromObject(data.select.start).isEqual(Point.fromObject(data.select.end))
      return unless editor.markBufferRange?
      editor.selectionMarker = editor.markBufferRange Range.fromObject(data.select), invalidate: 'never'
      editor.decorateMarker editor.selectionMarker, type: 'highlight', class: 'mp-selection'

  oncursor: (data) ->
    editor = atom.workspace.getActivePaneItem()
    return unless editor? and editor.getPath? and editor.markBufferPosition? and @locateFilePath(data) is editor.getPath()
    editor.remoteCursor?.marker.destroy()

    editor.remoteCursor = new RemoteCursorView(editor, data.cursor, data.userEmail)

    @setGravatarDuration(editor)

    editor.scrollToBufferPosition(data.cursor, {center: true})

  setGravatarDuration: (editor) ->
    gravatarDelay = 1500
    now = new Date().getTime()

    if now - @lastCursorChange < gravatarDelay
      clearInterval @gravatarTimeoutId
    @gravatarTimeoutId = setTimeout ->
      editor.remoteCursor?.gravatar.hide(300)
    , gravatarDelay

    @lastCursorChange = now

  locateProjectPath: (data) ->
    if @project.getPaths().length is 0
      return @project.getPaths()[0]
    if process.platform is "win32"
        correctData = data.filePath[0].replace(/\//g, "\\")
    else
        correctData = data.filePath[0].replace(/\\/g, "/")

    for path in @project.getPaths()
      if path.split(@seperator).pop() is correctData.split(@seperator).pop()
        return path

  locateFilePath: (data) ->
    if process.platform is "win32"
        correctData = data.filePath[1].replace(/\//g, "\\")
    else
        correctData = data.filePath[1]

    if data.filePath
      projectPath = @locateProjectPath(data)
      return projectPath + @seperator + correctData
    else
      return data.file

  sendFileEvents: (type , file) ->
    data = {
      a: 'meta',
      type: type,
      data: {
        file: @project.relativize(file),
        filePath: @project.relativizePath(file)
      }
    }

    unless @remoteAction
      @sendMessage data

  sendMessage: (data) ->
    try
      @remoteClient.send JSON.stringify(data)
    catch e
      @emitter.emit 'socket-not-opened'

  listen: ->

    @remoteClient.on 'message', (event) =>
      event = JSON.parse(event)

      if @["on#{event.type}"]?
        if atom.config.get('motepair.syncTabs') or event.type not in @syncTabsEvents
          @["on#{event.type}"](event.data)

    @subscriptions.add @workspace.observeTextEditors (editor) =>

      @subscriptions.add editor.onDidChangeCursorPosition (event) =>
        return if editor.suppress

        data = {
          a: 'meta',
          type: 'cursor',
          data: {
            file: @project.relativize(editor.getPath()),
            filePath: @project.relativizePath(editor.getPath()),
            cursor: event.newBufferPosition
            userEmail: @userEmail
          }
        }

        setTimeout => # cursor and selection data should be sent after op data
          @sendMessage data
        , 0

      @subscriptions.add editor.onDidChangeSelectionRange (event) =>
        data = {
          a: 'meta',
          type: 'select',
          data: {
            file: @project.relativize(editor.getPath()),
            filePath: @project.relativizePath(editor.getPath()),
            select: event.newBufferRange
          }
        }

        setTimeout =>
          @sendMessage data
        , 0

      @subscriptions.add editor.onDidSave (event) => @sendFileEvents('save', event.path)

    @subscriptions.add @workspace.onWillDestroyPaneItem (event) =>
      return unless event.item.getPath?()?

      event.item.detachShareJsDoc?()
      @sendFileEvents('close', event.item.getPath())

    @subscriptions.add @workspace.onDidChangeActivePaneItem (event) =>
      return unless event? and event.getPath? and event.getPath()? and @locateProjectPath({ filePath: @project.relativizePath(event.getPath())}) isnt null

      @sendFileEvents('open', event.getPath())


module.exports = EventHandler
