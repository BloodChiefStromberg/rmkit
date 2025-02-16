#include <fcntl.h>
#include <unistd.h>
#include <sys/select.h>
#include <linux/input.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>

#include "../defines.h"
#include "events.h"
#include "gestures.h"
#include "device_id.h"

using namespace std

USE_RESIM := true

// #define DEBUG_INPUT_EVENT 1
namespace input:
  static int ipc_fd[2] = { -1, -1 };
  CRASH_ON_BAD_DEVICE := getenv("RMKIT_CRASH_ON_BAD_DEVICE") != NULL

  template<class T, class EV>
  class InputClass:
    public:
    int fd
    input_event ev_data[64]
    T prev_ev, event
    vector<T> events


    InputClass():
      pass

    clear():
      self.events.clear()

    def marshal(T &ev):
      return ev.marshal()

    void unlock():
      ioctl(fd, EVIOCGRAB, false)

    void lock():
      ioctl(fd, EVIOCGRAB, true)

    void handle_event_fd():
      int bytes = read(fd, ev_data, sizeof(input_event) * 64);
      if bytes < sizeof(struct input_event) || bytes == -1:
        return

      #ifndef DEV
      // in DEV mode we allow event coalescing between calls to read() for
      // resim normally evdev will do one full event per read() call instead of
      // splitting across multiple read() calls
      T event = prev_ev
      #endif
      event.initialize()

      for int i = 0; i < bytes / sizeof(struct input_event); i++:
//        debug fd, "READ EVENT", ev_data[i].type, ev_data[i].code, ev_data[i].value
        if ev_data[i].type == EV_SYN:
          event.finalize()
          events.push_back(event)
          #ifdef DEBUG_INPUT_EVENT
          fprintf(stderr, "\n")
          #endif
          prev_ev = event
          event.initialize()
        else:
          event.update(ev_data[i])

  class Input:
    private:

    public:
    int max_fd
    fd_set rdfs

    InputClass<WacomEvent, SynMotionEvent> wacom
    InputClass<TouchEvent, SynMotionEvent> touch
    InputClass<ButtonEvent, SynKeyEvent> button

    vector<SynMotionEvent> all_motion_events
    vector<SynKeyEvent> all_key_events

    Input():
      FD_ZERO(&rdfs)

      // dev only
      // used by remarkable
      #ifdef REMARKABLE
      self.open_device("/dev/input/event0")
      self.open_device("/dev/input/event1")
      self.open_device("/dev/input/event2")
      #else
      if USE_RESIM:
        debug "MONITORING RESIM"
        self.monitor(self.wacom.fd = open("./event0", O_RDWR))
        self.monitor(self.touch.fd = open("./event1", O_RDWR))
        self.monitor(self.button.fd = open("./event2", O_RDWR))
      #endif

      #ifdef DEV_KBD
      if !USE_RESIM:
        self.monitor(self.button.fd = open(DEV_KBD, O_RDONLY))
      #endif

      if ipc_fd[0] == -1:
        socketpair(AF_UNIX, SOCK_STREAM, 0, ipc_fd)

      self.monitor(input::ipc_fd[0])
      return


    ~Input():
      close(self.touch.fd)
      close(self.wacom.fd)
      close(self.button.fd)

    void open_device(string fname):
      fd := open(fname.c_str(), O_RDWR)

      switch input::id_by_capabilities(fd):
        case STYLUS:
          self.wacom.fd = fd
          break
        case BUTTONS:
          self.button.fd = fd
          break
        case TOUCH:
          self.touch.fd = fd
          break
        case INVALID:
        case UNKNOWN:
        default:
          debug fname, "IS UNKNOWN EVENT DEVICE"
          close(fd)
          if CRASH_ON_BAD_DEVICE:
            exit(1)
          return

      self.monitor(fd)

    void reset_events():
      self.wacom.clear()
      self.touch.clear()
      self.button.clear()

      all_motion_events.clear()
      all_key_events.clear()

    void monitor(int fd):
      FD_SET(fd,&rdfs)
      max_fd = max(max_fd, fd+1)

    void unmonitor(int fd):
      FD_CLR(fd, &rdfs)

    def handle_ipc():
      char buf[1024];
      int bytes = read(input::ipc_fd[0], buf, 1024);

      return

    void grab():
      #ifndef REMARKABLE
      return
      #endif
      for auto fd : { self.touch.fd, self.wacom.fd, self.button.fd }:
        ioctl(fd, EVIOCGRAB, true)

    void ungrab():
      #ifndef REMARKABLE
      return
      #endif
      for auto fd : { self.touch.fd, self.wacom.fd, self.button.fd }:
        ioctl(fd, EVIOCGRAB, false)


    void listen_all(long timeout_ms = 0):
      fd_set rdfs_cp
      int retval
      self.reset_events()

      rdfs_cp = rdfs

      #ifdef DEV
      timeout_ms = 1000
      #endif

      if timeout_ms > 0:
          struct timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000}
          retval = select(max_fd, &rdfs_cp, NULL, NULL, &tv)
      else:
          retval = select(max_fd, &rdfs_cp, NULL, NULL, NULL)

      if retval > 0:
        if FD_ISSET(self.wacom.fd, &rdfs_cp):
          self.wacom.handle_event_fd()
        if FD_ISSET(self.touch.fd, &rdfs_cp):
          self.touch.handle_event_fd()
        if FD_ISSET(self.button.fd, &rdfs_cp):
          self.button.handle_event_fd()
        if FD_ISSET(input::ipc_fd[0], &rdfs_cp):
          self.handle_ipc()

      for auto ev : self.wacom.events:
        self.all_motion_events.push_back(self.wacom.marshal(ev))


      for auto ev : self.touch.events:
        self.all_motion_events.push_back(self.touch.marshal(ev))

      for auto ev : self.button.events:
        self.all_key_events.push_back(self.button.marshal(ev))

      #ifdef DEBUG_INPUT_EVENT
      for auto syn_ev : self.all_motion_events:
        debug "SYN MOUSE", syn_ev.x, syn_ev.y, syn_ev.pressure, syn_ev.left, syn_ev.eraser
      #endif
      return


  // TODO: should we just put this in the SynMotionEvent?
  static WacomEvent* is_wacom_event(SynMotionEvent &syn_ev):
    return dynamic_cast<WacomEvent*>(syn_ev.original.get())
  static TouchEvent* is_touch_event(SynMotionEvent &syn_ev):
    return dynamic_cast<TouchEvent*>(syn_ev.original.get())
