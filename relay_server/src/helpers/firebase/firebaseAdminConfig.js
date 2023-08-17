// Import the functions you need from the SDKs you need
const {
  initializeApp,
  applicationDefault,
  cert,
} = require("firebase-admin/app");
const {
  getFirestore,
  Timestamp,
  FieldValue,
} = require("firebase-admin/firestore");

const serviceAccount = require("./testing-account.json");
// const serviceAccount = require("./invisible.json");

initializeApp({
  credential: cert(serviceAccount),
  //   databaseURL: "https://invisibl333.firebaseio.com",
});

const db = getFirestore();

module.exports = { db };