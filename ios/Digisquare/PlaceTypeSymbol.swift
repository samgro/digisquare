//
//  PlaceTypeSymbol.swift
//  Digisquare
//

import Foundation

/// Maps Google Places API primary types to SF Symbols and display names.
///
/// The cases below cover Table A of the Places API type list
/// (https://developers.google.com/maps/documentation/places/web-service/place-types),
/// grouped the same way the docs group them.
enum PlaceTypeSymbol {
    static func systemImageName(for primaryType: String?) -> String {
        guard let primaryType else { return "mappin" }
        switch primaryType {
        // MARK: Automotive
        case "car_dealer", "car_rental":
            return "car.fill"
        case "car_repair":
            return "wrench.and.screwdriver.fill"
        case "car_wash":
            return "car.fill"
        case "electric_vehicle_charging_station":
            return "bolt.car.fill"
        case "gas_station":
            return "fuelpump.fill"
        case "parking", "park_and_ride":
            return "parkingsign"
        case "rest_stop", "truck_stop":
            return "road.lanes"

        // MARK: Business
        case "corporate_office":
            return "building.2.fill"
        case "farm", "ranch":
            return "leaf.fill"

        // MARK: Culture
        case "art_gallery", "art_studio", "sculpture":
            return "paintpalette.fill"
        case "auditorium", "concert_hall", "opera_house", "philharmonic_hall", "performing_arts_theater":
            return "theatermasks.fill"
        case "cultural_landmark", "historical_place", "historical_landmark", "monument":
            return "building.columns.fill"
        case "museum":
            return "building.columns.fill"

        // MARK: Education
        case "library":
            return "books.vertical.fill"
        case "preschool", "primary_school", "secondary_school", "school", "school_district":
            return "graduationcap.fill"
        case "university":
            return "graduationcap.fill"

        // MARK: Entertainment and Recreation
        case "amphitheatre", "event_venue", "wedding_venue", "banquet_hall", "convention_center":
            return "party.popper.fill"
        case "amusement_center", "amusement_park", "roller_coaster", "ferris_wheel":
            return "ticket.fill"
        case "aquarium":
            return "fish.fill"
        case "barbecue_area", "picnic_ground":
            return "flame.fill"
        case "botanical_garden", "garden":
            return "leaf.fill"
        case "bowling_alley":
            return "figure.bowling"
        case "casino":
            return "suit.club.fill"
        case "childrens_camp", "summer_camp_organizer":
            return "tent.fill"
        case "comedy_club", "night_club", "karaoke":
            return "music.mic"
        case "community_center", "cultural_center":
            return "person.3.fill"
        case "cycling_park":
            return "figure.outdoor.cycle"
        case "dance_hall":
            return "music.note"
        case "dog_park":
            return "dog.fill"
        case "hiking_area":
            return "figure.hiking"
        case "internet_cafe":
            return "network"
        case "marina":
            return "sailboat.fill"
        case "movie_rental", "movie_theater":
            return "theatermasks.fill"
        case "national_park", "state_park", "wildlife_park", "wildlife_refuge":
            return "tree.fill"
        case "observation_deck", "visitor_center", "tourist_attraction":
            return "binoculars.fill"
        case "off_roading_area":
            return "mountain.2.fill"
        case "park":
            return "tree.fill"
        case "planetarium":
            return "sparkles"
        case "plaza":
            return "square.grid.2x2.fill"
        case "skateboard_park":
            return "figure.skateboarding"
        case "video_arcade":
            return "gamecontroller.fill"
        case "water_park":
            return "figure.pool.swim"
        case "zoo":
            return "hare.fill"

        // MARK: Facilities
        case "public_bath", "public_bathroom":
            return "toilet.fill"
        case "stable":
            return "pawprint.fill"

        // MARK: Finance
        case "accounting":
            return "chart.pie.fill"
        case "atm":
            return "banknote.fill"
        case "bank":
            return "building.columns.fill"

        // MARK: Food and Drink
        case "cafe", "coffee_shop", "bakery", "tea_house", "cat_cafe", "dog_cafe":
            return "cup.and.saucer.fill"
        case "bar", "pub", "wine_bar", "bar_and_grill":
            return "wineglass.fill"
        case "acai_shop", "bagel_shop", "candy_store", "chocolate_factory", "chocolate_shop",
            "confectionery", "dessert_restaurant", "dessert_shop", "donut_shop", "ice_cream_shop",
            "juice_shop":
            return "birthday.cake.fill"
        case "cafeteria", "food_court", "buffet_restaurant":
            return "tray.fill"
        case "deli", "sandwich_shop":
            return "fork.knife"
        case "diner", "breakfast_restaurant", "brunch_restaurant", "fine_dining_restaurant",
            "steak_house", "seafood_restaurant", "restaurant":
            return "fork.knife"
        case "fast_food_restaurant", "hamburger_restaurant":
            return "takeoutbag.and.cup.and.straw.fill"
        case "meal_delivery", "meal_takeaway", "food_delivery":
            return "takeoutbag.and.cup.and.straw.fill"
        case "pizza_restaurant":
            return "fork.knife.circle.fill"

        // MARK: Geographical Areas
        case "administrative_area_level_1", "administrative_area_level_2", "country", "locality":
            return "map.fill"
        case "postal_code":
            return "envelope.fill"

        // MARK: Government
        case "city_hall", "courthouse", "government_office", "local_government_office":
            return "building.columns.fill"
        case "embassy":
            return "flag.fill"
        case "fire_station":
            return "flame.fill"
        case "neighborhood_police_station", "police":
            return "shield.fill"
        case "post_office":
            return "envelope.fill"

        // MARK: Health and Wellness
        case "chiropractor", "physiotherapist", "massage":
            return "figure.walk"
        case "dental_clinic", "dentist":
            return "cross.case.fill"
        case "doctor", "medical_lab", "skin_care_clinic":
            return "stethoscope"
        case "drugstore", "pharmacy":
            return "pills.fill"
        case "hospital":
            return "cross.fill"
        case "sauna", "spa", "tanning_studio", "wellness_center":
            return "figure.mind.and.body"
        case "yoga_studio":
            return "figure.yoga"

        // MARK: Housing
        case "apartment_building", "apartment_complex", "condominium_complex", "housing_development":
            return "building.fill"

        // MARK: Lodging
        case "hotel", "lodging", "resort_hotel", "extended_stay_hotel", "motel", "inn",
            "bed_and_breakfast", "guest_house", "private_guest_room":
            return "bed.double.fill"
        case "hostel":
            return "bed.double.fill"
        case "campground", "camping_cabin", "rv_park", "farmstay", "cottage", "mobile_home_park":
            return "tent.fill"
        case "budget_japanese_inn", "japanese_inn":
            return "bed.double.fill"

        // MARK: Natural Features
        case "beach":
            return "beach.umbrella.fill"

        // MARK: Places of Worship
        case "church":
            return "cross.fill"
        case "hindu_temple":
            return "building.columns.fill"
        case "mosque":
            return "building.columns.fill"
        case "synagogue":
            return "building.columns.fill"

        // MARK: Services
        case "astrologer", "psychic":
            return "sparkles"
        case "barber_shop", "hair_care", "hair_salon", "beautician", "beauty_salon", "makeup_artist",
            "nail_salon":
            return "scissors"
        case "body_art_service":
            return "paintbrush.pointed.fill"
        case "catering_service":
            return "takeoutbag.and.cup.and.straw.fill"
        case "cemetery", "funeral_home":
            return "leaf.fill"
        case "child_care_agency":
            return "figure.2.and.child.holdinghands"
        case "consultant":
            return "person.fill.questionmark"
        case "courier_service", "moving_company":
            return "shippingbox.fill"
        case "electrician":
            return "bolt.fill"
        case "florist":
            return "leaf.fill"
        case "foot_care":
            return "figure.walk"
        case "insurance_agency":
            return "checkmark.shield.fill"
        case "laundry":
            return "washer.fill"
        case "lawyer":
            return "building.columns.fill"
        case "locksmith":
            return "key.fill"
        case "painter":
            return "paintbrush.fill"
        case "plumber":
            return "wrench.and.screwdriver.fill"
        case "real_estate_agency":
            return "house.fill"
        case "roofing_contractor":
            return "house.fill"
        case "storage":
            return "shippingbox.fill"
        case "tailor":
            return "tshirt.fill"
        case "telecommunications_service_provider":
            return "antenna.radiowaves.left.and.right"
        case "tour_agency", "tourist_information_center", "travel_agency":
            return "airplane"
        case "veterinary_care":
            return "pawprint.fill"

        // MARK: Shopping
        case "store", "shopping_mall", "grocery_store", "supermarket", "convenience_store",
            "food_store", "market", "asian_grocery_store", "warehouse_store", "wholesaler",
            "discount_store", "department_store":
            return "bag.fill"
        case "auto_parts_store":
            return "car.fill"
        case "bicycle_store":
            return "bicycle"
        case "book_store":
            return "book.fill"
        case "butcher_shop":
            return "fork.knife"
        case "cell_phone_store", "electronics_store":
            return "iphone"
        case "clothing_store":
            return "tshirt.fill"
        case "furniture_store", "home_goods_store", "home_improvement_store":
            return "sofa.fill"
        case "gift_shop":
            return "gift.fill"
        case "hardware_store":
            return "hammer.fill"
        case "jewelry_store":
            return "sparkles"
        case "liquor_store":
            return "wineglass.fill"
        case "pet_store":
            return "pawprint.fill"
        case "shoe_store":
            return "bag.fill"
        case "sporting_goods_store":
            return "sportscourt.fill"

        // MARK: Sports
        case "arena", "stadium", "sports_complex":
            return "sportscourt.fill"
        case "athletic_field", "sports_activity_location":
            return "sportscourt.fill"
        case "fishing_charter", "fishing_pond":
            return "fish.fill"
        case "fitness_center", "gym", "sports_club", "sports_coaching":
            return "dumbbell.fill"
        case "golf_course":
            return "figure.golf"
        case "ice_skating_rink":
            return "figure.skating"
        case "playground":
            return "figure.and.child.holdinghands"
        case "ski_resort":
            return "figure.skiing.downhill"
        case "swimming_pool":
            return "figure.pool.swim"

        // MARK: Transportation
        case "airport", "airstrip", "international_airport", "heliport":
            return "airplane"
        case "bus_station", "bus_stop", "transit_depot", "transit_station":
            return "bus.fill"
        case "ferry_terminal":
            return "ferry.fill"
        case "funicular", "light_rail_station", "subway_station", "train_station":
            return "tram.fill"
        case "taxi_stand":
            return "car.fill"

        default:
            if primaryType.hasSuffix("restaurant") || primaryType.hasPrefix("meal_") {
                return "fork.knife"
            }
            if primaryType.hasSuffix("_store") || primaryType.hasSuffix("_shop") {
                return "bag.fill"
            }
            return "mappin"
        }
    }

    /// "coffee_shop" → "Coffee Shop"
    static func displayName(for primaryType: String) -> String {
        primaryType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
