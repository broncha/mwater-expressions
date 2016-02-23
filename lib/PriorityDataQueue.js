var PriorityDataQueue, PriorityDataSource, async;

async = require('async');

PriorityDataSource = require('./PriorityDataSource');

module.exports = PriorityDataQueue = (function() {
  function PriorityDataQueue(dataSource, concurrency) {
    var worker;
    this.dataSource = dataSource;
    worker = function(query, callback) {
      return dataSource.performQuery(query, callback);
    };
    this.performQueryPriorityQueue = new async.priorityQueue(worker, concurrency);
  }

  PriorityDataQueue.prototype.createPriorityDataSource = function(priority) {
    return new PriorityDataSource(this, priority);
  };

  PriorityDataQueue.prototype.performQuery = function(query, cb, priority) {
    return this.performQueryPriorityQueue.push(query, priority, cb);
  };

  PriorityDataQueue.prototype.getImageUrl = function(imageId, height) {
    return this.dataSource.getImageUrl(imageId, height);
  };

  PriorityDataQueue.prototype.kill = function() {
    if (this.performQueryPriorityQueue != null) {
      return this.performQueryPriorityQueue.kill();
    }
  };

  return PriorityDataQueue;

})();