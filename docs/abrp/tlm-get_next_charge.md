GET
get_next_charge
https://api.iternio.com/1/tlm/get_next_charge?token=<user token>
This method retrieves the user’s next charging goal for use in notifying them when their car has reached the desired charge level.

The result will contain the next charge-to goal [SoC %] for that user’s most recent plan:

Result properties:

next_charge [SoC %]: User's next goal charge value in percent (0-100)
Example response:

Plain Text
{
    "status": "ok",
    "result": {
        "next_charge": 86.0
    }
}
AUTHORIZATION
API Key
This request is using API Key from collectionIternio Telemetry API
PARAMS
token
<user token>

A token identifying the user. This token can be obtained using the live data setup guides in the ABRP app, or, preferably, using our OAuth2 API.

Example request:
curl --location 'https://api.iternio.com/1/tlm/get_next_charge?token=%3Cuser%20token%3E'
