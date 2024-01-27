
function getJson(response) {
  return response.json();
}

function getText(response) {
  return response.text();
}

function rejectIfNotOk(response) {
  if (response.ok) {
    return response;
  }
  return Promise.reject(response.statusText);
}

function rejectIfFailed(response) {
  if (response.success) {
    return response;
  }
  return Promise.reject(response.status);
}

function getResponse(responses, node) {
  return responses.find(function(r) { return r.node === node; });
}

function post(node, value) {
  return fetch('rest/fsapi/' + node + '/set', {
    method: 'POST',
    headers: {
      "Content-Type": "application/json"
    },
    body: '' + value
  }).then(rejectIfNotOk).then(getJson).then(rejectIfFailed);
}

var config = Vue.observable({
});

var homeTemplate = {
  template: '#home-template',
  data: function() {
    return {
      config: config,
      name: '',
      firstLine: '',
      secondLine: '',
      on: false,
      volume: 0,
      muted: false,
      edit: false
    };
  },
  //beforeRouteEnter: function(to, from, next) { next(); },
  //beforeRouteUpdate: function(to, from, next) { next(); },
  //mounted: function() {},
  created() {
    this.$root.$refs.home = this;
    this.refresh();
  },
  methods: {
    changeVolume: function(delta) {
      var self = this;
      var volume = this.volume + delta;
      post('netRemote.sys.audio.volume', volume).then(function(response) {
        self.volume = volume;
      });
    },
    toggleMute: function() {
      var self = this;
      post('netRemote.sys.audio.mute', this.muted ? 0 : 1).then(function(response) {
        self.muted = !self.muted;
      });
    },
    togglePower: function() {
      var self = this;
      post('netRemote.sys.power', this.on ? 0 : 1).then(function(response) {
        self.on = !self.on;
      });
    },
    refresh: function() {
      var self = this;
      fetch('rest/fsapi/get-multiple', {
        method: 'POST',
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify([
          'netRemote.sys.power',
          'netRemote.sys.audio.volume',
          'netRemote.sys.audio.mute',
          'netRemote.play.info.name',
          'netRemote.play.info.text',
          'netRemote.sys.info.friendlyName'
        ])
      }).then(rejectIfNotOk).then(getJson).then(function(responses) {
        console.log('response ' + JSON.stringify(responses));
        self.on = getResponse(responses, 'netRemote.sys.power').value === 1;
        self.muted = getResponse(responses, 'netRemote.sys.audio.mute').value === 1;
        self.volume = getResponse(responses, 'netRemote.sys.audio.volume').value || 0;
        self.name = getResponse(responses, 'netRemote.sys.info.friendlyName').value || '';
        self.firstLine = getResponse(responses, 'netRemote.play.info.name').value || '';
        self.secondLine = getResponse(responses, 'netRemote.play.info.text').value || '';
      });
    }
  }
};

var infoTemplate = {
  template: '#info-template',
  data: function() {
    return {
      config: config
    };
  }
};

var router = new VueRouter({
  routes: [
    { path: '/', component: homeTemplate },
    { path: '/info', component: infoTemplate }
  ]
});

var app = new Vue({
  data: function() {
    return {
      message: ''
    };
  },
  mounted: function() {
    this.showMessage('Welcome', 1000);
  },
  methods: {
    showMessage: function(message, delay) {
      this.message = message;
      var self = this;
      setTimeout(function() {
        self.message = '';
      }, delay || 3000);
    }
  },
  router: router
}).$mount('#app');
