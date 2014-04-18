module.exports = (prefix)->

  initial = last = Date.now()

  @next = (label)->
    next = Date.now()
    console.log '[' + new Date + ']', (prefix && '[' + prefix + ']' || ''), label, (next - last) + 'ms/' + (next-initial) + 'ms'
    last = next

  @